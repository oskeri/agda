-- | A syntactic equality check that takes meta instantiations into account,
--   but does not reduce.  It replaces
--   @
--      (v, v') <- instantiateFull (v, v')
--      v == v'
--   @
--   by a more efficient routine which only traverses and instantiates the terms
--   as long as they are equal.

module Agda.TypeChecking.SyntacticEquality
  ( SynEq
  , checkSyntacticEquality
  , syntacticEqualityFuelRemains
  )
  where

import Control.Arrow            ( (***) )
import Control.Monad            ( zipWithM )
import Control.Monad.State      ( MonadState(..), StateT, runStateT )
import Control.Monad.Trans      ( lift )

import Agda.Interaction.Options ( optSyntacticEquality )

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Monad
  (ReduceM, MonadReduce(..), TCEnv(..), MonadTCEnv(..), pragmaOptions,
   isInstantiatedMeta)
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute

import qualified Agda.Utils.Maybe.Strict as Strict
import Agda.Utils.Monad (ifM, and2M)

-- | Syntactic equality check for terms. If syntactic equality
-- checking has fuel left, then 'checkSyntacticEquality' behaves as if
-- it were implemented in the following way (which does not match the
-- given type signature), only that @v@ and @v'@ are only fully
-- instantiated to the depth where they are equal (and the amount of
-- fuel is reduced by one unit in the failure branch):
--   @
--      checkSyntacticEquality v v' s f = do
--        (v, v') <- instantiateFull (v, v')
--        if v == v' then s v v' else f v v'
--   @
-- If syntactic equality checking does not have fuel left, then
-- 'checkSyntacticEquality' instantiates the two terms and takes the
-- failure branch.
--
-- Note that in either case the returned values @v@ and @v'@ cannot be
-- @MetaV@s that are instantiated.

{-# SPECIALIZE checkSyntacticEquality ::
      Term -> Term ->
      (Term -> Term -> ReduceM a) ->
      (Term -> Term -> ReduceM a) ->
      ReduceM a #-}
{-# SPECIALIZE checkSyntacticEquality ::
      Type -> Type ->
      (Type -> Type -> ReduceM a) ->
      (Type -> Type -> ReduceM a) ->
      ReduceM a #-}
checkSyntacticEquality
  :: (Instantiate a, SynEq a, MonadReduce m)
  => a
  -> a
  -> (a -> a -> m b)  -- ^ Continuation used upon success.
  -> (a -> a -> m b)  -- ^ Continuation used upon failure, or if
                      --   syntactic equality checking has been turned
                      --   off.
  -> m b
checkSyntacticEquality v v' s f =
  ifM syntacticEqualityFuelRemains
  {-then-} (do ((v, v'), equal) <-
                 liftReduce $ synEq v v' `runStateT` True
               if equal then s v v' else localTC decreaseFuel (f v v'))
  {-else-} (uncurry f =<< instantiate (v,v'))
  where
  decreaseFuel env =
    case envSyntacticEqualityFuel env of
      Strict.Nothing -> env
      Strict.Just n  ->
        env { envSyntacticEqualityFuel = Strict.Just (pred n) }

-- | Does the syntactic equality check have any remaining fuel?

syntacticEqualityFuelRemains :: MonadReduce m => m Bool
syntacticEqualityFuelRemains = do
  fuel <- envSyntacticEqualityFuel <$> askTC
  return $ case fuel of
    Strict.Nothing -> True
    Strict.Just n  -> n > 0

-- | Monad for checking syntactic equality
type SynEqM = StateT Bool ReduceM

-- | Return, flagging inequalty.
inequal :: a -> SynEqM a
inequal a = put False >> return a

-- | If inequality is flagged, return, else continue.
ifEqual :: (a -> SynEqM a) -> (a -> SynEqM a)
ifEqual cont a = ifM get (cont a) (return a)

-- Since List2 is only Applicative, not a monad, I cannot
-- define a List2T monad transformer, so we do it manually:

(<$$>) :: Functor f => (a -> b) -> f (a, a) -> f (b, b)
f <$$> xx = (f *** f) <$> xx

pure2 :: Applicative f => a -> f (a, a)
pure2 a = pure (a, a)

(<**>) :: Applicative f => f (a -> b, a -> b) -> f (a, a) -> f (b, b)
ff <**> xx = (uncurry (***)) <$> ff <*> xx

-- | Instantiate full as long as things are equal
class SynEq a where
  synEq  :: a -> a -> SynEqM (a, a)
  synEq' :: a -> a -> SynEqM (a, a)
  synEq' a a' = ifEqual (uncurry synEq) (a, a')

instance SynEq Bool where
  synEq x y | x == y    = return (x, y)
  synEq x y | otherwise = inequal (x, y)

-- | Syntactic term equality ignores 'DontCare' stuff.
instance SynEq Term where
  synEq v v' = do
    (v, v') <- lift $ instantiate' (v, v')
    case (v, v') of
      (Var   i vs, Var   i' vs') | i == i' -> Var i   <$$> synEq vs vs'
      (Con c i vs, Con c' i' vs') | c == c' -> Con c (bestConInfo i i') <$$> synEq vs vs'
      (Def   f vs, Def   f' vs') | f == f' -> Def f   <$$> synEq vs vs'
      (MetaV x vs, MetaV x' vs') | x == x' -> MetaV x <$$> synEq vs vs'
      (Lit   l   , Lit   l'    ) | l == l' -> pure2 $ v
      (Lam   h b , Lam   h' b' )           -> Lam <$$> synEq h h' <**> synEq b b'
      (Level l   , Level l'    )           -> levelTm <$$> synEq l l'
      (Sort  s   , Sort  s'    )           -> Sort    <$$> synEq s s'
      (Pi    a b , Pi    a' b' )           -> Pi      <$$> synEq a a' <**> synEq' b b'
      (DontCare u, DontCare u' )           -> DontCare <$$> synEq u u'
         -- Irrelevant things are not syntactically equal. ALT:
         -- pure (u, u')
         -- Jesper, 2019-10-21: considering irrelevant things to be
         -- syntactically equal causes implicit arguments to go
         -- unsolved, so it is better to go under the DontCare.
      (Dummy{}   , Dummy{}     )           -> pure (v, v')
      _                                    -> inequal (v, v')

instance SynEq Level where
  synEq l@(Max n vs) l'@(Max n' vs')
    | n == n'   = levelMax n <$$> synEq vs vs'
    | otherwise = inequal (l, l')

instance SynEq PlusLevel where
  synEq l@(Plus n v) l'@(Plus n' v')
    | n == n'   = Plus n <$$> synEq v v'
    | otherwise = inequal (l, l')

instance SynEq Sort where
  synEq s s' = do
    (s, s') <- lift $ instantiate' (s, s')
    case (s, s') of
      (Type l  , Type l'   ) -> Type <$$> synEq l l'
      (PiSort a b c, PiSort a' b' c') -> piSort <$$> synEq a a' <**> synEq' b b' <**> synEq' c c'
      (FunSort a b, FunSort a' b') -> funSort <$$> synEq a a' <**> synEq' b b'
      (UnivSort a, UnivSort a') -> UnivSort <$$> synEq a a'
      (SizeUniv, SizeUniv  ) -> pure2 s
      (LockUniv, LockUniv  ) -> pure2 s
      (IntervalUniv, IntervalUniv) -> pure2 s
      (Prop l  , Prop l'   ) -> Prop <$$> synEq l l'
      (Inf f m , Inf f' n) | f == f', m == n -> pure2 s
      (SSet l  , SSet l'   ) -> SSet <$$> synEq l l'
      (MetaS x es , MetaS x' es') | x == x' -> MetaS x <$$> synEq es es'
      (DefS  d es , DefS  d' es') | d == d' -> DefS d  <$$> synEq es es'
      (DummyS{}, DummyS{}) -> pure (s, s')
      _ -> inequal (s, s')

-- | Syntactic equality ignores sorts.
instance SynEq Type where
  synEq (El s t) (El s' t') = (El s *** El s') <$> synEq t t'

instance SynEq a => SynEq [a] where
  synEq as as'
    | length as == length as' = unzip <$> zipWithM synEq' as as'
    | otherwise               = inequal (as, as')

instance (SynEq a, SynEq b) => SynEq (a,b) where
  synEq (a,b) (a',b') = (,) <$$> synEq a a' <**> synEq b b'

instance SynEq a => SynEq (Elim' a) where
  synEq e e' =
    case (e, e') of
      (Proj _ f, Proj _ f') | f == f' -> pure2 e
      (Apply a, Apply a') -> Apply <$$> synEq a a'
      (IApply u v r, IApply u' v' r')
                          -> (IApply u v *** IApply u' v') <$> synEq r r'
      _                   -> inequal (e, e')

instance (Subst a, SynEq a) => SynEq (Abs a) where
  synEq a a' =
    case (a, a') of
      (NoAbs x b, NoAbs x' b') -> (NoAbs x *** NoAbs x') <$>  synEq b b'
      (Abs   x b, Abs   x' b') -> (Abs x *** Abs x') <$> synEq b b'
      (Abs   x b, NoAbs x' b') -> Abs x  <$$> synEq b (raise 1 b')  -- TODO: mkAbs?
      (NoAbs x b, Abs   x' b') -> Abs x' <$$> synEq (raise 1 b) b'

-- NOTE: Do not ignore 'ArgInfo', or test/fail/UnequalHiding will pass.
instance SynEq a => SynEq (Arg a) where
  synEq (Arg ai a) (Arg ai' a') = Arg <$$> synEq ai ai' <**> synEq a a'

-- Ignore the tactic.
instance SynEq a => SynEq (Dom a) where
  synEq d@(Dom ai b x t a) d'@(Dom ai' b' x' _ a')
    | x == x'   = Dom <$$> synEq ai ai' <**> synEq b b' <**> pure2 x <**> pure2 t <**> synEq a a'
    | otherwise = inequal (d, d')

instance SynEq ArgInfo where
  synEq ai@(ArgInfo h r o _ a) ai'@(ArgInfo h' r' o' _ a')
    | h == h', sameModality r r', a == a' = pure2 ai
    | otherwise        = inequal (ai, ai')
