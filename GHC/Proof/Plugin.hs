-- | See "GHC.Proof".
{-# LANGUAGE CPP #-}
module GHC.Proof.Plugin (plugin) where

import Prelude hiding ((<>))
import Data.Maybe
import Control.Monad
import System.Exit

import GhcPlugins
import Simplify
import CoreStats
import CoreMonad
import SimplMonad
import OccurAnal
import FamInstEnv
import SimplEnv
import CSE

-- import GHC.Proof

plugin :: Plugin
plugin = defaultPlugin { installCoreToDos = install }

install :: [CommandLineOption] -> [CoreToDo] -> CoreM [CoreToDo]
install _ (simpl:xs) = return $ simpl: myOccurPass : pass : xs
  where pass = CoreDoPluginPass "GHC.Proof" proofPass
        myOccurPass = CoreDoPluginPass "GHC.Proof Occur" occurPass


type Task = (SDoc, Bool, [CoreBndr], CoreExpr, CoreExpr)

findProofTasks :: ModGuts -> CoreM [Task]
findProofTasks guts = return $ mapMaybe findProofTask (mg_binds guts)


findProofTask :: CoreBind -> Maybe Task
findProofTask (NonRec name e)
    | (bndrs, body) <- collectBinders e
    , (Var v `App` Type _ `App` e1 `App` e2) <- body
    , isProof (idName v)
    = Just (ppr name, True, bndrs, e1,e2)
findProofTask (NonRec name e)
    | (bndrs, body) <- collectBinders e
    , (Var v `App` Type _ `App` e1 `App` e2) <- body
    , isNonProof (idName v)
    = Just (ppr name, False, bndrs, e1,e2)
findProofTask _ = Nothing


isProof :: Name -> Bool
isProof n =
    occNameString oN == "proof" &&
    moduleNameString (moduleName (nameModule n)) == "GHC.Proof"
 || occNameString oN == "===" &&
    moduleNameString (moduleName (nameModule n)) == "GHC.Proof"
  where oN = occName n

isNonProof :: Name -> Bool
isNonProof n =
    occNameString oN == "non_proof" &&
    moduleNameString (moduleName (nameModule n)) == "GHC.Proof"
 || occNameString oN == "=/=" &&
    moduleNameString (moduleName (nameModule n)) == "GHC.Proof"
  where oN = occName n


proveTask :: ModGuts -> Task -> CoreM Bool
proveTask guts (name, really, bndrs, e1, e2) = do
    if really
      then putMsg (text "GHC.Proof: Proving" <+> name <+> text "…")
      else putMsg (text "GHC.Proof: Not proving" <+> name <+> text "…")

    se1 <- simplify guts bndrs e1
    se2 <- simplify guts bndrs e2
    let differences = diffExpr False (mkRnEnv2 emptyInScopeSet) se1 se2

    if really
      then
        if null differences
          then return True
          else do
            putMsg $
                text "Proof failed" $$
                nest 4 (hang (text "Simplified LHS" <> colon) 4 (ppr se1)) $$
                nest 4 (hang (text "Simplified RHS" <> colon) 4 (ppr se2))
                -- nest 4 (text "Differences:") $$
                -- nest 4 (itemize differences)
            return False
      else
        if null differences
          then do
            putMsg $ text "Proof succeeded unexpectedly"
            return False
          else do
            return True

itemize :: [SDoc] -> SDoc
itemize = vcat . map (char '•' <+>)

simplify :: ModGuts -> [Var] -> CoreExpr -> CoreM CoreExpr
simplify guts more_in_scope expr = do
    dflags <- getDynFlags

#if  __GLASGOW_HASKELL__ >= 801
    let dflags' = dflags { ufUseThreshold = 1000, ufVeryAggressive = True } --yeeha!
#else
    let dflags' = dflags { ufUseThreshold = 1000 }
#endif
    us <- liftIO $ mkSplitUniqSupply 's'
    let sz = exprSize expr

    hpt_rule_base <- getRuleBase
    hsc_env <- getHscEnv
    eps <- liftIO $ hscEPS hsc_env
    let rule_base1 = unionRuleBase hpt_rule_base (eps_rule_base eps)
        rule_base2 = extendRuleBaseList rule_base1 (mg_rules guts)
    vis_orphs <- getVisibleOrphanMods
    let rule_env = RuleEnv rule_base2 vis_orphs
    let in_scope = bindersOfBinds (mg_binds guts) ++ more_in_scope

    (expr', _) <- liftIO $ initSmpl dflags' rule_env emptyFamInstEnvs us sz $
            return expr
                >>= simplExpr (simplEnv in_scope 4 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 4 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 3 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 3 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 2 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 2 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 2 dflags') . occurAnalyseExpr
                >>= simplExpr (simplEnv in_scope 1 dflags') . occurAnalyseExpr . cseOneExpr'
                >>= simplExpr (simplEnv in_scope 1 dflags') . occurAnalyseExpr . cseOneExpr'
                >>= simplExpr (simplEnv in_scope 0 dflags') . occurAnalyseExpr . cseOneExpr'
                >>= simplExpr (simplEnv in_scope 0 dflags') . occurAnalyseExpr . cseOneExpr'
    return expr'

#if  __GLASGOW_HASKELL__ >= 801
cseOneExpr' = cseOneExpr
#else
cseOneExpr' = id
#endif

simplEnv :: [Var] -> Int -> DynFlags -> SimplEnv
simplEnv vars p dflags = env1
  where
    env1 = addNewInScopeIds env0 vars
    env0 =  mkSimplEnv $ SimplMode { sm_names = ["GHC.Proof"]
                                   , sm_phase = Phase p
#if  __GLASGOW_HASKELL__ >= 804
                                   , sm_dflags = dflags
#endif
                                   , sm_rules = True
                                   , sm_inline = True
                                   , sm_eta_expand = True
                                   , sm_case_case = True }

proofPass :: ModGuts -> CoreM ModGuts
proofPass guts = do

    dflags <- getDynFlags
    when (optLevel dflags < 1) $
        warnMsg $ fsep $ map text $ words "GHC.Proof: Compilation without -O detected. Expect proofs to fail."


    tasks <- findProofTasks guts
    ok <- and <$> mapM (proveTask guts) tasks
    if ok
      then do
        let n = length [ () | (_, True, _, _, _) <- tasks ]
        let m = length [ () | (_, False, _, _, _) <- tasks ]
        putMsg $ text "GHC.Proof proved" <+> ppr n <+> text "equalities"
        return guts
      else do
        errorMsg $ text "GHC.Proof could not prove all equalities"
        liftIO $ exitFailure -- kill the compiler. Is there a nicer way?

#if  __GLASGOW_HASKELL__ >= 806
occurPass :: CorePluginPass
#else
occurPass :: PluginPass
#endif
occurPass mg@ModGuts { mg_module = this_mod
                            , mg_rdr_env = rdr_env
                            , mg_deps = deps
                            , mg_binds = binds, mg_rules = rules
                            , mg_fam_inst_env = fam_inst_env }
#if  __GLASGOW_HASKELL__ >= 806
 = do let binds' = occurAnalysePgm this_mod (const True) (const True) rules binds
#else
 = do let binds' = occurAnalysePgm this_mod (const True) rules [] emptyVarSet  binds
#endif
      return mg
