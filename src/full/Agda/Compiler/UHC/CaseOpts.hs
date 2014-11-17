-- | Perform simple optimisations based on case-laws
module Agda.Compiler.UHC.CaseOpts where

import Control.Applicative

import Agda.TypeChecking.Monad

import Agda.Compiler.UHC.AuxAST
import Agda.Compiler.UHC.AuxASTUtil
import Agda.Compiler.UHC.CompileState

caseOpts :: [Fun] -> Compile TCM [Fun]
caseOpts = mapM  $ \ def -> case def of
  Fun{} -> do
    e' <- caseOptsExpr (xfunExpr def)
    return def { xfunExpr = e' }
  _     -> return def

-- | Run the case-opts on an expression
caseOptsExpr :: Expr -> Compile TCM Expr
caseOptsExpr expr = case expr of
  Var v       -> return $ Var v
  Lit l       -> return $ Lit l
  Lam v e     -> Lam v <$> caseOptsExpr e
  Con c n es  -> Con c n <$> mapM caseOptsExpr es
  App v es    -> apps v <$> mapM caseOptsExpr es
  -- If there is only one constructor branch, perform a projection to get the result
  Case e [Branch {brVars = vs, brExpr = eorg}] -> do
      e' <- caseOptsExpr eorg
      bindExpr e $ \var ->
        return $ foldr (\(v, n) -> lett v $ App "proj" [Lit (LInt n), Var var]) e'
               $ zip vs [0..]
  -- If there is only a default branch, the case is not necessary
  Case e [Default{brExpr = e'}] -> caseOptsExpr e'
  Case e brs  -> Case <$> caseOptsExpr e <*> (mapM (\br -> do e' <- caseOptsExpr (brExpr br)
                                                              return br {brExpr = e'}) brs)
  Let v e1 e2 -> Let v <$> caseOptsExpr e1 <*> caseOptsExpr e2
  UNIT        -> return UNIT
  IMPOSSIBLE  -> return IMPOSSIBLE
