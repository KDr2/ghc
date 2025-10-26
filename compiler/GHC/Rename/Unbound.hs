{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

{-

This module contains helper functions for reporting and creating
unbound variables.

-}
module GHC.Rename.Unbound
   ( mkUnboundName
   , mkUnboundNameRdr
   , mkUnboundGRE
   , mkUnboundGRERdr
   , isUnboundName
   , reportUnboundName
   , unknownNameSuggestions
   , unknownNameSuggestionsMessage
   , similarNameSuggestions
   , fieldSelectorSuggestions
   , anyQualImportSuggestions
   , WhatLooking(..)
   , WhereLooking(..)
   , LookingFor(..)
   , unboundName
   , unboundNameX
   , unboundTermNameInTypes
   , IsTermInTypes(..)
   , notInScopeErr
   , relevantNameSpace
   , suggestionIsRelevant
   , termNameInType
   )
where

import GHC.Prelude

import GHC.Driver.DynFlags
import GHC.Driver.Ppr
import GHC.Driver.Env (hsc_units)
import GHC.Driver.Env.Types

import {-# SOURCE #-} GHC.Tc.Errors.Hole ( getHoleFitDispConfig )
import GHC.Tc.Errors.Types
import GHC.Tc.Utils.Monad
import GHC.Builtin.Names ( mkUnboundName, isUnboundName )
import GHC.Utils.Misc
import GHC.Utils.Panic (panic)

import GHC.Data.Maybe
import GHC.Data.FastString

import qualified GHC.LanguageExtensions as LangExt

import GHC.Types.Hint
  ( GhcHint (SuggestExtension, RemindFieldSelectorSuppressed, ImportSuggestion, SuggestSimilarNames)
  , LanguageExtensionHint (SuggestSingleExtension)
  , ImportSuggestion(..), SimilarName(..), HowInScope(..) )
import GHC.Types.SrcLoc as SrcLoc
import GHC.Types.Name
import GHC.Types.Name.Reader

import GHC.Unit.Module
import GHC.Unit.Module.Imported
import GHC.Utils.Outputable
import GHC.Runtime.Context

import GHC.Data.Bag
import Language.Haskell.Syntax.ImpExp

import Data.List (sortBy, partition)
import Data.List.NonEmpty ( pattern (:|), NonEmpty )
import qualified Data.List.NonEmpty as NE ( nonEmpty )
import Data.Function ( on )
import qualified Data.Semigroup as S
import qualified Data.Map as M

{-
************************************************************************
*                                                                      *
               What to do when a lookup fails
*                                                                      *
************************************************************************
-}

data WhereLooking = WL_Anywhere   -- Any binding
                  | WL_Global     -- Any top-level binding (local or imported)
                  | WL_LocalTop   -- Any top-level binding in this module
                  | WL_LocalOnly
                        -- Only local bindings
                        -- (pattern synonyms declarations,
                        -- see Note [Renaming pattern synonym variables]
                        -- in GHC.Rename.Bind)

data LookingFor = LF { lf_which :: WhatLooking
                     , lf_where :: WhereLooking
                     }

data IsTermInTypes = UnknownTermInTypes RdrName | TermInTypes RdrName | NoTermInTypes

mkUnboundNameRdr :: RdrName -> Name
mkUnboundNameRdr rdr = mkUnboundName (rdrNameOcc rdr)

mkUnboundGRE :: OccName -> GlobalRdrElt
mkUnboundGRE occ = mkLocalGRE UnboundGRE NoParent $ mkUnboundName occ

mkUnboundGRERdr :: RdrName -> GlobalRdrElt
mkUnboundGRERdr rdr = mkLocalGRE UnboundGRE NoParent $ mkUnboundNameRdr rdr

reportUnboundName :: WhatLooking -> RdrName -> RnM Name
reportUnboundName what_look rdr = unboundName (LF what_look WL_Anywhere) rdr

unboundName :: LookingFor -> RdrName -> RnM Name
unboundName lf rdr = unboundNameX lf rdr []

unboundNameX :: LookingFor -> RdrName -> [GhcHint] -> RnM Name
unboundNameX looking_for rdr_name hints
  = unboundNameOrTermInType NoTermInTypes looking_for rdr_name hints

unboundTermNameInTypes :: LookingFor -> RdrName -> RdrName  -> RnM Name
unboundTermNameInTypes looking_for rdr_name demoted_rdr_name
  = unboundNameOrTermInType (UnknownTermInTypes demoted_rdr_name) looking_for rdr_name []

-- Catches imported qualified terms in type signatures
-- with proper error message and suggestions
termNameInType :: LookingFor -> RdrName -> RdrName -> [GhcHint] -> RnM Name
termNameInType looking_for rdr_name demoted_rdr_name external_hints
  = unboundNameOrTermInType (TermInTypes demoted_rdr_name) looking_for rdr_name external_hints

unboundNameOrTermInType :: IsTermInTypes -> LookingFor -> RdrName -> [GhcHint] -> RnM Name
unboundNameOrTermInType if_term_in_type looking_for rdr_name hints
  = do  { dflags <- getDynFlags
        ; let show_helpful_errors = gopt Opt_HelpfulErrors dflags
        ; if not show_helpful_errors
          then addErr =<< make_error [] hints
          else do { local_env  <- getLocalRdrEnv
                  ; global_env <- getGlobalRdrEnv
                  ; impInfo <- getImports
                  ; currmod <- getModule
                  ; ic <- hsc_IC <$> getTopEnv
                  ; let (imp_errs, suggs) =
                          unknownNameSuggestions_ looking_for
                            dflags ic currmod global_env local_env impInfo
                            rdr_name
                  ; traceTc "unboundNameOrTermInType" $
                     vcat [ text "rdr_name:" <+> ppr rdr_name
                          , text "what_looking:" <+> text (show $ lf_which looking_for)
                          , text "imp_errs:" <+> ppr imp_errs
                          , text "suggs:" <+> ppr suggs
                          ]
                  ; addErr =<<
                      make_error imp_errs (hints ++ suggs) }
        ; return (mkUnboundNameRdr rdr_name) }
    where
      name_to_search = case if_term_in_type of
        NoTermInTypes                   -> rdr_name
        UnknownTermInTypes demoted_name -> demoted_name
        TermInTypes demoted_name        -> demoted_name

      err = notInScopeErr (lf_where looking_for) name_to_search

      make_error imp_errs hints =
        case if_term_in_type of
          TermInTypes demoted_name ->
            unknownNameSuggestionsMessage (TcRnTermNameInType demoted_name)
              [] -- no import errors
              hints
          _ -> unknownNameSuggestionsMessage (TcRnNotInScope err name_to_search)
                 imp_errs hints

unknownNameSuggestionsMessage :: TcRnMessage -> [ImportError] -> [GhcHint] -> RnM TcRnMessage
unknownNameSuggestionsMessage msg imp_errs hints
  = do { unit_state <- hsc_units <$> getTopEnv
       ; hfdc <- getHoleFitDispConfig
       ; let supp = case NE.nonEmpty imp_errs of
                       Nothing -> Nothing
                       Just ne_imp_errs ->
                         (Just (hfdc, [SupplementaryImportErrors ne_imp_errs]))
       ; return $
           TcRnMessageWithInfo unit_state $
             mkDetailedMessage (ErrInfo [] supp hints) msg
       }

notInScopeErr :: WhereLooking -> RdrName -> NotInScopeError
notInScopeErr where_look rdr_name
  | Just name <- isExact_maybe rdr_name
  = NoExactName name
  | WL_LocalTop <- where_look
  = NoTopLevelBinding
  | otherwise
  = NotInScope

-- | Called from the typechecker ("GHC.Tc.Errors") when we find an unbound variable
unknownNameSuggestions :: LocalRdrEnv -> WhatLooking -> RdrName -> RnM ([ImportError], [GhcHint])
unknownNameSuggestions lcl_env what_look tried_rdr_name =
  do { dflags  <- getDynFlags
     ; rdr_env <- getGlobalRdrEnv
     ; imp_info <- getImports
     ; curr_mod <- getModule
     ; interactive_context <- hsc_IC <$> getTopEnv
     ; return $
        unknownNameSuggestions_
          (LF what_look WL_Anywhere)
          dflags interactive_context curr_mod rdr_env lcl_env imp_info tried_rdr_name }

unknownNameSuggestions_ :: LookingFor -> DynFlags -> InteractiveContext
                       -> Module
                       -> GlobalRdrEnv -> LocalRdrEnv -> ImportAvails
                       -> RdrName -> ([ImportError], [GhcHint])
unknownNameSuggestions_ looking_for dflags hpt curr_mod global_env local_env
                          imports tried_rdr_name = (imp_errs, suggs)
  where
    suggs = mconcat
      [ if_ne (SuggestSimilarNames tried_rdr_name) $
          similarNameSuggestions looking_for dflags global_env local_env tried_rdr_name
      , map (ImportSuggestion $ rdrNameOcc tried_rdr_name) imp_suggs
      , extensionSuggestions tried_rdr_name
      , fieldSelectorSuggestions global_env tried_rdr_name ]
    (imp_errs, imp_suggs) = sameQualImportSuggestions looking_for hpt curr_mod imports tried_rdr_name

    if_ne :: (NonEmpty a -> b) -> [a] -> [b]
    if_ne _ []       = []
    if_ne f (a : as) = [f (a :| as)]

-- | When the name is in scope as field whose selector has been suppressed by
-- NoFieldSelectors, display a helpful message explaining this.
fieldSelectorSuggestions :: GlobalRdrEnv -> RdrName -> [GhcHint]
fieldSelectorSuggestions global_env tried_rdr_name
  | null gres = []
  | otherwise = [RemindFieldSelectorSuppressed tried_rdr_name parents]
  where
    gres = filter isNoFieldSelectorGRE
         $ lookupGRE global_env (LookupRdrName tried_rdr_name AllRelevantGREs)
    parents = [ parent | ParentIs parent <- map greParent gres ]

similarNameSuggestions :: LookingFor -> DynFlags
                       -> GlobalRdrEnv -> LocalRdrEnv
                       -> RdrName -> [SimilarName]
similarNameSuggestions looking_for@(LF what_look where_look) dflags global_env
                       local_env tried_rdr_name
  = fuzzyLookup (showPpr dflags tried_rdr_name) all_possibilities
  where
    all_possibilities :: [(String, SimilarName)]
    all_possibilities = case what_look of
      WL_None -> []
      _ -> [ (showPpr dflags r, SimilarRdrName r Nothing (Just $ LocallyBoundAt loc))
           | (r,loc) <- local_possibilities local_env ]
        ++ [ (showPpr dflags r, rp) | (r, rp) <- global_possibilities global_env ]

    tried_occ     = rdrNameOcc tried_rdr_name
    tried_is_sym  = isSymOcc tried_occ
    tried_is_qual = isQual tried_rdr_name

    is_relevant sugg_occ =
      suggestionIsRelevant dflags what_look sugg_occ
        && isSymOcc sugg_occ == tried_is_sym
        -- Treat operator and non-operators as non-matching
        -- This heuristic avoids things like
        --      Not in scope 'f'; perhaps you meant '+' (from Prelude)

    local_ok = case where_look of { WL_Anywhere  -> True
                                  ; WL_LocalOnly -> True
                                  ; _            -> False }

    local_possibilities :: LocalRdrEnv -> [(RdrName, SrcSpan)]
    local_possibilities env
      | tried_is_qual = []
      | not local_ok  = []
      | otherwise     = [ (mkRdrUnqual occ, nameSrcSpan name)
                        | name <- localRdrEnvElts env
                        , let occ = nameOccName name
                        , is_relevant occ
                        ]

    global_possibilities :: GlobalRdrEnv -> [(RdrName, SimilarName)]
    global_possibilities global_env
      | tried_is_qual = [ (rdr_qual, SimilarRdrName rdr_qual (Just gre) (Just how))
                        | gre <- globalRdrEnvElts global_env
                        , isGreOk looking_for gre
                        , let occ = greOccName gre
                        , is_relevant occ
                        , (mod, how) <- qualsInScope gre
                        , let rdr_qual = mkRdrQual mod occ ]

      | otherwise = [ (rdr_unqual, sim)
                    | gre <- globalRdrEnvElts global_env
                    , isGreOk looking_for gre
                    , let occ = greOccName gre
                          rdr_unqual = mkRdrUnqual occ
                    , is_relevant occ
                    , sim <- case (unquals_in_scope gre, quals_only gre) of
                                (how:_, _)    -> [ SimilarRdrName rdr_unqual (Just gre) (Just how) ]
                                ([],    pr:_) -> [ pr ]  -- See Note [Only-quals]
                                ([],    [])   -> [] ]

              -- Note [Only-quals]
              -- ~~~~~~~~~~~~~~~~~
              -- The second alternative returns those names with the same
              -- OccName as the one we tried, but live in *qualified* imports
              -- e.g. if you have:
              --
              -- > import qualified Data.Map as Map
              -- > foo :: Map
              --
              -- then we suggest @Map.Map@.

    --------------------
    unquals_in_scope :: GlobalRdrElt -> [HowInScope]
    unquals_in_scope (gre@GRE { gre_lcl = lcl, gre_imp = is })
      | lcl       = [ LocallyBoundAt (greDefinitionSrcSpan gre) ]
      | otherwise = [ ImportedBy ispec
                    | i <- bagToList is, let ispec = is_decl i
                    , not (is_qual ispec) ]


    --------------------
    quals_only :: GlobalRdrElt -> [SimilarName]
    -- Ones for which *only* the qualified version is in scope
    quals_only (gre@GRE { gre_imp = is })
      = [ (SimilarRdrName (mkRdrQual (is_as ispec) (greOccName gre)) (Just gre) (Just $ ImportedBy ispec))
        | i <- bagToList is, let ispec = is_decl i, is_qual ispec ]

-- | Provide import suggestions, without filtering by module qualification.
-- Used to suggest imports for 'HasField', which doesn't care about whether a
-- name is imported qualified or unqualified.
--
-- For example:
--
--  > import M1 () -- M1 exports fld1
--  > import qualified M2 hiding ( fld2 )
--  > x r = r.fld1              -- suggest adding 'fld1' to M1 import
--  > y r = getField @"fld2" r  -- suggest unhiding 'fld' from M2 import
anyQualImportSuggestions :: LookingFor -> LookupGRE GREInfo -> TcM [ImportSuggestion]
anyQualImportSuggestions looking_for lookup_gre =
  do { imp_info <- getImports
     ; let interesting_imports = interestingImports imp_info (const True)
     ; return $
          importSuggestions_ looking_for interesting_imports lookup_gre
     }

-- | The given 'RdrName' is not in scope. Try to find out why that is by looking
-- at the import list, to suggest e.g. changing the import list somehow.
--
-- For example:
--
-- > import qualified M1 hiding ( blah1 )
-- > x = M1.blah -- suggest unhiding blah1
-- > y = XX.blah1 -- import error: no imports provide the XX qualification prefix
sameQualImportSuggestions
  :: LookingFor
  -> InteractiveContext
  -> Module
  -> ImportAvails
  -> RdrName
  -> ([ImportError], [ImportSuggestion])
sameQualImportSuggestions looking_for ic currMod imports rdr_name
  | not (isQual rdr_name || isUnqual rdr_name) = ([], [])
  | Just rdr_mod_name <- mb_rdr_mod_name
  , show_not_imported_line rdr_mod_name
  = ([MissingModule rdr_mod_name], [])
  | is_qualified
  , null import_suggs
  , (mod : mods) <- map fst interesting_imports
  = ([ModulesDoNotExport (mod :| mods) (lf_which looking_for) occ_name], [])
  | otherwise
  = ([], import_suggs)
  where

  interesting_imports = interestingImports imports right_qual_import

  import_suggs =
    importSuggestions_ looking_for interesting_imports $
      (LookupOccName (rdrNameOcc rdr_name) $ RelevantGREsFOS WantNormal)

  is_qualified = isQual rdr_name
  (mb_rdr_mod_name, occ_name) = case rdr_name of
    Unqual occ_name        -> (Nothing, occ_name)
    Qual mod_name occ_name -> (Just mod_name, occ_name)
    _                      -> panic "sameQualImportSuggestions: dead code"

  -- See Note [When to show/hide the module-not-imported line]
  show_not_imported_line :: ModuleName -> Bool                    -- #15611
  show_not_imported_line modnam
      | not (null interactive_imports)        = False -- 1 (interactive context)
      | not (null interesting_imports)        = False -- 1 (normal module import)
      | moduleName currMod == modnam          = False -- 2
      | otherwise                             = True

  -- Choose the imports from the interactive context which might have provided
  -- a module.
  interactive_imports =
    filter pick_interactive (ic_imports ic)

  pick_interactive :: InteractiveImport -> Bool
  pick_interactive (IIDecl d)   | mb_rdr_mod_name == Just (unLoc (ideclName d)) = True
                                | mb_rdr_mod_name == fmap unLoc (ideclAs d) = True
  pick_interactive (IIModule m) | mb_rdr_mod_name == Just (moduleName m) = True
  pick_interactive _ = False

  right_qual_import imv =
    case mb_rdr_mod_name of
      -- Qual RdrName: only want qualified imports with the same module name
      Just rdr_mod_name -> imv_name imv == rdr_mod_name
      -- UnQual RdrName: import must be unqualified
      Nothing           -> not (imv_qualified imv)

-- | What import statements are relevant?
--
--   - If we are looking for a qualified name @Mod.blah@, which imports provide @Mod@ at all,
--   - If we are looking for an unqualified name, which imports are themselves unqualified.
interestingImports :: ImportAvails -> (ImportedModsVal -> Bool) -> [(Module, ImportedModsVal)]
interestingImports imports ok_mod_name =
  [ (mod, imp)
    | (mod, mod_imports) <- M.toList (imp_mods imports)
    , Just imp <- return $ pick (importedByUser mod_imports)
    ]

  where
  -- We want to keep only one for each original module; preferably one with an
  -- explicit import list (for no particularly good reason)
  pick :: [ImportedModsVal] -> Maybe ImportedModsVal
  pick = listToMaybe . sortBy cmp . filter ok_mod_name
    where
      cmp = on compare imv_is_hiding S.<> on SrcLoc.leftmost_smallest imv_span

importSuggestions_
  :: LookingFor
  -> [(Module, ImportedModsVal)]
  -> LookupGRE GREInfo
  -> [ImportSuggestion]
importSuggestions_ looking_for interesting_imports lookup_gre
  | WL_LocalOnly <- lf_where looking_for       = []
  | WL_LocalTop  <- lf_where looking_for       = []
  | mod : mods <- helpful_imports_non_hiding
  = [CouldImportFrom (mod :| mods)]
  | mod : mods <- helpful_imports_hiding
  = [CouldUnhideFrom (mod :| mods)]
  | otherwise
  = []
 where

  -- Which of these would export a 'foo'
  -- (all of these are restricted imports, because if they were not, we
  -- wouldn't have an out-of-scope error in the first place)
  helpful_imports = filter helpful interesting_imports
    where helpful (_,imv)
            = any (isGreOk looking_for) $
              lookupGRE (imv_all_exports imv)
                lookup_gre

  -- Which of these do that because of an explicit hiding list resp. an
  -- explicit import list
  (helpful_imports_hiding, helpful_imports_non_hiding)
    = partition (imv_is_hiding . snd) helpful_imports

extensionSuggestions :: RdrName -> [GhcHint]
extensionSuggestions rdrName
  | rdrName == mkUnqual varName (fsLit "mdo") ||
    rdrName == mkUnqual varName (fsLit "rec")
  = [SuggestExtension $ SuggestSingleExtension empty LangExt.RecursiveDo]
  | otherwise
  = []

qualsInScope :: GlobalRdrElt -> [(ModuleName, HowInScope)]
-- Ones for which the qualified version is in scope
qualsInScope gre@GRE { gre_lcl = lcl, gre_imp = is }
      | lcl = case greDefinitionModule gre of
                Nothing -> []
                Just m  -> [(moduleName m, LocallyBoundAt (greDefinitionSrcSpan gre))]
      | otherwise = [ (is_as ispec, ImportedBy ispec)
                    | i <- bagToList is, let ispec = is_decl i ]

isGreOk :: LookingFor -> GlobalRdrElt -> Bool
isGreOk (LF what_look where_look) gre = what_ok && where_ok
  where
    -- when looking for record fields, what_ok checks whether the GRE is a
    -- record field. Otherwise, it checks whether the GRE is a record field
    -- defined in a module with -XNoFieldSelectors - it wouldn't be a useful
    -- suggestion in that case.
    what_ok  = case what_look of
                 WL_RecField -> isRecFldGRE gre
                 _           -> not (isNoFieldSelectorGRE gre)

    where_ok = case where_look of
                 WL_LocalTop  -> isLocalGRE gre
                 WL_LocalOnly -> False
                 _            -> True

-- | Is it OK to suggest an identifier in some other 'NameSpace',
-- given what we are looking for?
--
-- See Note [Related name spaces]
suggestionIsRelevant
  :: DynFlags    -- ^ to find out whether -XDataKinds is enabled
  -> WhatLooking -- ^ What kind of name are we looking for?
  -> OccName     -- ^ The suggestion
                 --
                 -- We only look at the suggestion's 'NameSpace',
                 -- but passing the whole 'OccName' is convenient
                 -- for debugging.
  -> Bool
suggestionIsRelevant dflags what_looking suggestion =
  relevantNameSpace data_kinds what_looking suggestion_ns
    where
      suggestion_ns = occNameSpace suggestion
      data_kinds = xopt LangExt.DataKinds dflags

-- | Is a 'NameSpace' relevant for what we are looking for?
relevantNameSpace :: Bool        -- ^ is @-XDataKinds@ enabled?
                  -> WhatLooking -- ^ what are we looking for?
                  -> NameSpace   -- ^ is this 'NameSpace' relevant?
                  -> Bool
relevantNameSpace data_kinds = \case
  WL_Anything         -> const True
  WL_TyCon            -> isTcClsNameSpace
  WL_TyCon_or_TermVar -> isTcClsNameSpace <||> isTermVarOrFieldNameSpace
  WL_TyVar            -> isTvNameSpace
  WL_Constructor      -> isTcClsNameSpace <||> isDataConNameSpace
  WL_ConLike          -> isDataConNameSpace
  WL_RecField         -> isFieldNameSpace
  WL_Term             -> isValNameSpace
  WL_TermVariable     -> isTermVarOrFieldNameSpace
  WL_Type             -> if data_kinds
                         then not . isTermVarOrFieldNameSpace
                         else not . isValNameSpace
  WL_None             -> const False

{- Note [Related name spaces]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Name spaces are related if there is a chance to mean the one when one writes
the other, i.e. variables <-> data constructors and type variables <-> type
constructors.

In most contexts, this mistake can happen in both directions. Not so in
patterns:

When a user writes
        foo (just a) = ...
It is possible that they meant to use `Just` instead. However, when they write
        foo (Map a) = ...
It is unlikely that they mean to use `map`, since variables cannot be used here.

Similarly, when we look for record fields, data constructors are not in a
related namespace.

Furthermore, with -XDataKinds, the data constructor name space is related to
the type variable and type constructor name spaces.

Note [When to show/hide the module-not-imported line]           -- #15611
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For the error message:
    Not in scope X.Y
    Module X does not export Y
    No module named ‘X’ is imported:
there are 2 cases, where we hide the last "no module is imported" line:
1. If the module X has been imported (normally or via interactive context).
2. It is the current module we are trying to compile
   then we can use the getModule function to get the current module name.
   (See test T15611a)
-}
