{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- instance Diagnostic TcRnMessage
{-# LANGUAGE RecordWildCards #-}

module GHC.Tc.Errors.Ppr (
    formatLevPolyErr
  , pprLevityPolyInType
  ) where

import GHC.Prelude

import GHC.Core.Class (Class(..))
import GHC.Core.Coercion (pprCoAxBranchUser)
import GHC.Core.Coercion.Axiom (coAxiomTyCon, coAxiomSingleBranch)
import GHC.Core.FamInstEnv (famInstAxiom)
import GHC.Core.InstEnv
import GHC.Core.TyCo.Ppr (pprKind, pprParendType, pprType, pprWithTYPE, pprWithExplicitKindsWhen)
import GHC.Core.Type
import GHC.Data.Bag
import GHC.Tc.Errors.Types
import GHC.Tc.Types.Rank (Rank(..))
import GHC.Tc.Utils.TcType (tcSplitForAllTyVars)
import GHC.Types.Error
import GHC.Types.FieldLabel (flIsOverloaded, flSelector)
import GHC.Types.Id (isRecordSelector)
import GHC.Types.Name
import GHC.Types.Name.Reader (GreName(..), pprNameProvenance)
import GHC.Types.SrcLoc (GenLocated(..))
import GHC.Types.TyThing
import GHC.Types.Var.Env (emptyTidyEnv)
import GHC.Types.Var.Set (pprVarSet, pluralVarSet)
import GHC.Driver.Flags
import GHC.Hs
import GHC.Utils.Outputable
import GHC.Utils.Misc (capitalise)
import GHC.Unit.State (pprWithUnitState, UnitState)
import qualified GHC.LanguageExtensions as LangExt
import qualified Data.List.NonEmpty as NE


instance Diagnostic TcRnMessage where
  diagnosticMessage = \case
    TcRnUnknownMessage m
      -> diagnosticMessage m
    TcLevityPolyInType ty prov (ErrInfo extra supplementary)
      -> mkDecorated [pprLevityPolyInType ty prov, extra, supplementary]
    TcRnMessageWithInfo unit_state msg_with_info
      -> case msg_with_info of
           TcRnMessageDetailed err_info msg
             -> messageWithInfoDiagnosticMessage unit_state err_info (diagnosticMessage msg)
    TcRnImplicitLift id_or_name ErrInfo{..}
      -> mkDecorated $
           ( text "The variable" <+> quotes (ppr id_or_name) <+>
             text "is implicitly lifted in the TH quotation"
           ) : [errInfoContext, errInfoSupplementary]
    TcRnUnusedPatternBinds bind
      -> mkDecorated [hang (text "This pattern-binding binds no variables:") 2 (ppr bind)]
    TcRnDodgyImports name
      -> mkDecorated [dodgy_msg (text "import") name (dodgy_msg_insert name :: IE GhcPs)]
    TcRnDodgyExports name
      -> mkDecorated [dodgy_msg (text "export") name (dodgy_msg_insert name :: IE GhcRn)]
    TcRnMissingImportList ie
      -> mkDecorated [ text "The import item" <+> quotes (ppr ie) <+>
                       text "does not have an explicit import list"
                     ]
    TcRnUnsafeDueToPlugin
      -> mkDecorated [text "Use of plugins makes the module unsafe"]
    TcRnModMissingRealSrcSpan mod
      -> mkDecorated [text "Module does not have a RealSrcSpan:" <+> ppr mod]
    TcRnIdNotExportedFromModuleSig name mod
      -> mkDecorated [ text "The identifier" <+> ppr (occName name) <+>
                       text "does not exist in the signature for" <+> ppr mod
                     ]
    TcRnIdNotExportedFromLocalSig name
      -> mkDecorated [ text "The identifier" <+> ppr (occName name) <+>
                       text "does not exist in the local signature."
                     ]
    TcRnShadowedName occ provenance
      -> let shadowed_locs = case provenance of
               ShadowedNameProvenanceLocal n     -> [text "bound at" <+> ppr n]
               ShadowedNameProvenanceGlobal gres -> map pprNameProvenance gres
         in mkSimpleDecorated $
            sep [text "This binding for" <+> quotes (ppr occ)
             <+> text "shadows the existing binding" <> plural shadowed_locs,
                   nest 2 (vcat shadowed_locs)]
    TcRnDuplicateWarningDecls d rdr_name
      -> mkSimpleDecorated $
           vcat [text "Multiple warning declarations for" <+> quotes (ppr rdr_name),
                 text "also at " <+> ppr (getLocA d)]
    TcRnSimplifierTooManyIterations simples limit wc
      -> mkSimpleDecorated $
           hang (text "solveWanteds: too many iterations"
                   <+> parens (text "limit =" <+> ppr limit))
                2 (vcat [ text "Unsolved:" <+> ppr wc
                        , text "Simples:"  <+> ppr simples
                        ])
    TcRnIllegalPatSynDecl rdrname
      -> mkSimpleDecorated $
           hang (text "Illegal pattern synonym declaration for" <+> quotes (ppr rdrname))
              2 (text "Pattern synonym declarations are only valid at top level")
    TcRnLinearPatSyn ty
      -> mkSimpleDecorated $
           hang (text "Pattern synonyms do not support linear fields (GHC #18806):") 2 (ppr ty)
    TcRnEmptyRecordUpdate
      -> mkSimpleDecorated $ text "Empty record update"
    TcRnIllegalFieldPunning fld
      -> mkSimpleDecorated $ text "Illegal use of punning for field" <+> quotes (ppr fld)
    TcRnIllegalWildcardsInRecord fld_part
      -> mkSimpleDecorated $ text "Illegal `..' in record" <+> pprRecordFieldPart fld_part
    TcRnDuplicateFieldName fld_part dups
      -> mkSimpleDecorated $
           hsep [text "duplicate field name",
                 quotes (ppr (NE.head dups)),
                 text "in record", pprRecordFieldPart fld_part]
    TcRnIllegalViewPattern pat
      -> mkSimpleDecorated $ vcat [text "Illegal view pattern: " <+> ppr pat]
    TcRnCharLiteralOutOfRange c
      -> mkSimpleDecorated $ text "character literal out of range: '\\" <> char c  <> char '\''
    TcRnIllegalWildcardsInConstructor con
      -> mkSimpleDecorated $
           vcat [ text "Illegal `..' notation for constructor" <+> quotes (ppr con)
                , nest 2 (text "The constructor has no labelled fields") ]
    TcRnIgnoringAnnotations anns
      -> mkSimpleDecorated $
           text "Ignoring ANN annotation" <> plural anns <> comma
           <+> text "because this is a stage-1 compiler without -fexternal-interpreter or doesn't support GHCi"
    TcRnAnnotationInSafeHaskell
      -> mkSimpleDecorated $
           vcat [ text "Annotations are not compatible with Safe Haskell."
                , text "See https://gitlab.haskell.org/ghc/ghc/issues/10826" ]
    TcRnInvalidTypeApplication fun_ty hs_ty
      -> mkSimpleDecorated $
           text "Cannot apply expression of type" <+> quotes (ppr fun_ty) $$
           text "to a visible type argument" <+> quotes (ppr hs_ty)
    TcRnTagToEnumMissingValArg
      -> mkSimpleDecorated $
           text "tagToEnum# must appear applied to one value argument"
    TcRnTagToEnumUnspecifiedResTy ty
      -> mkSimpleDecorated $
           hang (text "Bad call to tagToEnum# at type" <+> ppr ty)
              2 (vcat [ text "Specify the type by giving a type signature"
                      , text "e.g. (tagToEnum# x) :: Bool" ])
    TcRnTagToEnumResTyNotAnEnum ty
      -> mkSimpleDecorated $
           hang (text "Bad call to tagToEnum# at type" <+> ppr ty)
              2 (text "Result type must be an enumeration type")
    TcRnArrowIfThenElsePredDependsOnResultTy
      -> mkSimpleDecorated $
           text "Predicate type of `ifThenElse' depends on result type"
    TcRnArrowCommandExpected cmd
      -> mkSimpleDecorated $
           vcat [text "The expression", nest 2 (ppr cmd),
                 text "was found where an arrow command was expected"]
    TcRnIllegalHsBootFileDecl
      -> mkSimpleDecorated $
           text "Illegal declarations in an hs-boot file"
    TcRnRecursivePatternSynonym binds
      -> mkSimpleDecorated $
            hang (text "Recursive pattern synonym definition with following bindings:")
               2 (vcat $ map pprLBind . bagToList $ binds)
          where
            pprLoc loc = parens (text "defined at" <+> ppr loc)
            pprLBind :: GenLocated (SrcSpanAnn' a) (HsBindLR GhcRn idR) -> SDoc
            pprLBind (L loc bind) = pprWithCommas ppr (collectHsBindBinders CollNoDictBinders bind)
                                        <+> pprLoc (locA loc)
    TcRnPartialTypeSigTyVarMismatch n1 n2 fn_name hs_ty
      -> mkSimpleDecorated $
           hang (text "Couldn't match" <+> quotes (ppr n1)
                   <+> text "with" <+> quotes (ppr n2))
                2 (hang (text "both bound by the partial type signature:")
                        2 (ppr fn_name <+> dcolon <+> ppr hs_ty))
    TcRnPartialTypeSigBadQuantifier n fn_name hs_ty
      -> mkSimpleDecorated $
           hang (text "Can't quantify over" <+> quotes (ppr n))
                2 (hang (text "bound by the partial type signature:")
                        2 (ppr fn_name <+> dcolon <+> ppr hs_ty))
    TcRnPolymorphicBinderMissingSig n ty
      -> mkSimpleDecorated $
           sep [ text "Polymorphic local binding with no type signature:"
               , nest 2 $ pprPrefixName n <+> dcolon <+> ppr ty ]
    TcRnOverloadedSig sig
      -> mkSimpleDecorated $
           hang (text "Overloaded signature conflicts with monomorphism restriction")
              2 (ppr sig)
    TcRnTupleConstraintInst _
      -> mkSimpleDecorated $ text "You can't specify an instance for a tuple constraint"
    TcRnAbstractClassInst clas
      -> mkSimpleDecorated $
           text "Cannot define instance for abstract class" <+>
           quotes (ppr (className clas))
    TcRnNoClassInstHead tau
      -> mkSimpleDecorated $
           hang (text "Instance head is not headed by a class:") 2 (pprType tau)
    TcRnUserTypeError ty
      -> mkSimpleDecorated (pprUserTypeErrorTy ty)
    TcRnConstraintInKind ty
      -> mkSimpleDecorated $
           text "Illegal constraint in a kind:" <+> pprType ty
    TcRnUnboxedTupleTypeFuncArg ty
      -> mkSimpleDecorated $
           sep [ text "Illegal unboxed tuple type as function argument:"
               , pprType ty ]
    TcRnLinearFuncInKind ty
      -> mkSimpleDecorated $
           text "Illegal linear function in a kind:" <+> pprType ty
    TcRnForAllEscapeError ty kind
      -> mkSimpleDecorated $ vcat
           [ hang (text "Quantified type's kind mentions quantified type variable")
                2 (text "type:" <+> quotes (ppr ty))
           , hang (text "where the body of the forall has this kind:")
                2 (quotes (pprKind kind)) ]
    TcRnVDQInTermType ty
      -> mkSimpleDecorated $ vcat
           [ hang (text "Illegal visible, dependent quantification" <+>
                   text "in the type of a term:")
                2 (pprType ty)
           , text "(GHC does not yet support this)" ]
    TcRnIllegalEqualConstraints ty
      -> mkSimpleDecorated $
           text "Illegal equational constraint" <+> pprType ty
    TcRnBadQuantPredHead ty
      -> mkSimpleDecorated $
           hang (text "Quantified predicate must have a class or type variable head:")
              2 (pprType ty)
    TcRnIllegalTupleConstraint ty
      -> mkSimpleDecorated $
           text "Illegal tuple constraint:" <+> pprType ty
    TcRnNonTypeVarArgInConstraint ty
      -> mkSimpleDecorated $
           hang (text "Non type-variable argument")
              2 (text "in the constraint:" <+> pprType ty)
    TcRnIllegalImplicitParam ty
      -> mkSimpleDecorated $
           text "Illegal implicit parameter" <+> quotes (pprType ty)
    TcRnIllegalConstraintSynonymOfKind kind
      -> mkSimpleDecorated $
           text "Illegal constraint synonym of kind:" <+> quotes (pprKind kind)
    TcRnIllegalClassInst tcf
      -> mkSimpleDecorated $
           vcat [ text "Illegal instance for a" <+> ppr tcf
                , text "A class instance must be for a class" ]
    TcRnOversaturatedVisibleKindArg ty
      -> mkSimpleDecorated $
           text "Illegal oversaturated visible kind argument:" <+>
           quotes (char '@' <> pprParendType ty)
    TcRnBadAssociatedType clas tc
      -> mkSimpleDecorated $
           hsep [ text "Class", quotes (ppr clas)
                , text "does not have an associated type", quotes (ppr tc) ]
    TcRnForAllRankErr rank ty
      -> let herald = case tcSplitForAllTyVars ty of
               ([], _) -> text "Illegal qualified type:"
               _       -> text "Illegal polymorphic type:"
             extra = case rank of
               MonoTypeConstraint -> text "A constraint must be a monotype"
               _                  -> empty
         in mkSimpleDecorated $ vcat [hang herald 2 (pprType ty), extra]
    TcRnMonomorphicBindings bindings
      -> let pp_bndrs = pprBindings bindings
         in mkSimpleDecorated $
              sep [ text "The Monomorphism Restriction applies to the binding"
                  <> plural bindings
                  , text "for" <+> pp_bndrs ]
    TcRnOrphanInstance inst
      -> mkSimpleDecorated $
           hsep [ text "Orphan instance:"
                , pprInstanceHdr inst
                ]
    TcRnFunDepConflict unit_state sorted
      -> let herald = text "Functional dependencies conflict between instance declarations:"
         in mkSimpleDecorated $
              pprWithUnitState unit_state $ (hang herald 2 (pprInstances $ NE.toList sorted))
    TcRnDupInstanceDecls unit_state sorted
      -> let herald = text "Duplicate instance declarations:"
         in mkSimpleDecorated $
              pprWithUnitState unit_state $ (hang herald 2 (pprInstances $ NE.toList sorted))
    TcRnConflictingFamInstDecls sortedNE
      -> let sorted = NE.toList sortedNE
         in mkSimpleDecorated $
              hang (text "Conflicting family instance declarations:")
                 2 (vcat [ pprCoAxBranchUser (coAxiomTyCon ax) (coAxiomSingleBranch ax)
                         | fi <- sorted
                         , let ax = famInstAxiom fi ])
    TcRnFamInstNotInjective rea fam_tc (eqn1 NE.:| rest_eqns)
      -> let (herald, show_kinds) = case rea of
               InjErrRhsBareTyVar tys ->
                 (injectivityErrorHerald $$
                  text "RHS of injective type family equation is a bare" <+>
                  text "type variable" $$
                  text "but these LHS type and kind patterns are not bare" <+>
                  text "variables:" <+> pprQuotedList tys, False)
               InjErrRhsCannotBeATypeFam ->
                 (injectivityErrorHerald $$
                   text "RHS of injective type family equation cannot" <+>
                   text "be a type family:", False)
               InjErrRhsOverlap ->
                  (text "Type family equation right-hand sides overlap; this violates" $$
                   text "the family's injectivity annotation:", False)
               InjErrCannotInferFromRhs tvs has_kinds _ ->
                 let show_kinds = has_kinds == YesHasKinds
                     what = if show_kinds then text "Type/kind" else text "Type"
                     body = sep [ what <+> text "variable" <>
                                  pluralVarSet tvs <+> pprVarSet tvs (pprQuotedList . scopedSort)
                                , text "cannot be inferred from the right-hand side." ]
                     in (injectivityErrorHerald $$ body $$ text "In the type family equation:", show_kinds)

         in mkSimpleDecorated $ pprWithExplicitKindsWhen show_kinds $
              hang herald
                2 (vcat (map (pprCoAxBranchUser fam_tc) (eqn1 : rest_eqns)))
    TcRnBangOnUnliftedType ty
      -> mkSimpleDecorated $
           text "Strictness flag has no effect on unlifted type" <+> quotes (ppr ty)
    TcRnMultipleDefaultDeclarations dup_things
      -> mkSimpleDecorated $
           hang (text "Multiple default declarations")
              2 (vcat (map pp dup_things))
         where
           pp :: LDefaultDecl GhcRn -> SDoc
           pp (L locn (DefaultDecl _ _))
             = text "here was another default declaration" <+> ppr (locA locn)
    TcRnBadDefaultType ty deflt_clss
      -> mkSimpleDecorated $
           hang (text "The default type" <+> quotes (ppr ty) <+> text "is not an instance of")
              2 (foldr1 (\a b -> a <+> text "or" <+> b) (map (quotes. ppr) deflt_clss))
    TcRnPatSynBundledWithNonDataCon
      -> mkSimpleDecorated $
           text "Pattern synonyms can be bundled only with datatypes."
    TcRnPatSynBundledWithWrongType expected_res_ty res_ty
      -> mkSimpleDecorated $
           text "Pattern synonyms can only be bundled with matching type constructors"
               $$ text "Couldn't match expected type of"
               <+> quotes (ppr expected_res_ty)
               <+> text "with actual type of"
               <+> quotes (ppr res_ty)
    TcRnDupeModuleExport mod
      -> mkSimpleDecorated $
           hsep [ text "Duplicate"
                , quotes (text "Module" <+> ppr mod)
                , text "in export list" ]
    TcRnExportedModNotImported mod
      -> mkSimpleDecorated
       $ formatExportItemError
           (text "module" <+> ppr mod)
           "is not imported"
    TcRnNullExportedModule mod
      -> mkSimpleDecorated
       $ formatExportItemError
           (text "module" <+> ppr mod)
           "exports nothing"
    TcRnMissingExportList mod
      -> mkSimpleDecorated
       $ formatExportItemError
           (text "module" <+> ppr mod)
           "is missing an export list"
    TcRnExportHiddenComponents export_item
      -> mkSimpleDecorated
       $ formatExportItemError
           (ppr export_item)
           "attempts to export constructors or class methods that are not visible here"
    TcRnDuplicateExport child ie1 ie2
      -> mkSimpleDecorated $
           hsep [ quotes (ppr child)
                , text "is exported by", quotes (ppr ie1)
                , text "and",            quotes (ppr ie2) ]
    TcRnExportedParentChildMismatch parent_name ty_thing child parent_names
      -> mkSimpleDecorated $
           text "The type constructor" <+> quotes (ppr parent_name)
                 <+> text "is not the parent of the" <+> text what_is
                 <+> quotes thing <> char '.'
                 $$ text (capitalise what_is)
                    <> text "s can only be exported with their parent type constructor."
                 $$ (case parents of
                       [] -> empty
                       [_] -> text "Parent:"
                       _  -> text "Parents:") <+> fsep (punctuate comma parents)
      where
        pp_category :: TyThing -> String
        pp_category (AnId i)
          | isRecordSelector i = "record selector"
        pp_category i = tyThingCategory i
        what_is = pp_category ty_thing
        thing = ppr child
        parents = map ppr parent_names
    TcRnConflictingExports occ child1 gre1 ie1 child2 gre2 ie2
      -> mkSimpleDecorated $
           vcat [ text "Conflicting exports for" <+> quotes (ppr occ) <> colon
                , ppr_export child1 gre1 ie1
                , ppr_export child2 gre2 ie2
                ]
      where
        ppr_export child gre ie = nest 3 (hang (quotes (ppr ie) <+> text "exports" <+>
                                                quotes (ppr_name child))
                                            2 (pprNameProvenance gre))

        -- DuplicateRecordFields means that nameOccName might be a mangled
        -- $sel-prefixed thing, in which case show the correct OccName alone
        -- (but otherwise show the Name so it will have a module qualifier)
        ppr_name (FieldGreName fl) | flIsOverloaded fl = ppr fl
                                   | otherwise         = ppr (flSelector fl)
        ppr_name (NormalGreName name) = ppr name

  diagnosticReason = \case
    TcRnUnknownMessage m
      -> diagnosticReason m
    TcLevityPolyInType{}
      -> ErrorWithoutFlag
    TcRnMessageWithInfo _ msg_with_info
      -> case msg_with_info of
           TcRnMessageDetailed _ m -> diagnosticReason m
    TcRnImplicitLift{}
      -> WarningWithFlag Opt_WarnImplicitLift
    TcRnUnusedPatternBinds{}
      -> WarningWithFlag Opt_WarnUnusedPatternBinds
    TcRnDodgyImports{}
      -> WarningWithFlag Opt_WarnDodgyImports
    TcRnDodgyExports{}
      -> WarningWithFlag Opt_WarnDodgyExports
    TcRnMissingImportList{}
      -> WarningWithFlag Opt_WarnMissingImportList
    TcRnUnsafeDueToPlugin{}
      -> WarningWithoutFlag
    TcRnModMissingRealSrcSpan{}
      -> ErrorWithoutFlag
    TcRnIdNotExportedFromModuleSig{}
      -> ErrorWithoutFlag
    TcRnIdNotExportedFromLocalSig{}
      -> ErrorWithoutFlag
    TcRnShadowedName{}
      -> WarningWithFlag Opt_WarnNameShadowing
    TcRnDuplicateWarningDecls{}
      -> ErrorWithoutFlag
    TcRnSimplifierTooManyIterations{}
      -> ErrorWithoutFlag
    TcRnIllegalPatSynDecl{}
      -> ErrorWithoutFlag
    TcRnLinearPatSyn{}
      -> ErrorWithoutFlag
    TcRnEmptyRecordUpdate
      -> ErrorWithoutFlag
    TcRnIllegalFieldPunning{}
      -> ErrorWithoutFlag
    TcRnIllegalWildcardsInRecord{}
      -> ErrorWithoutFlag
    TcRnDuplicateFieldName{}
      -> ErrorWithoutFlag
    TcRnIllegalViewPattern{}
      -> ErrorWithoutFlag
    TcRnCharLiteralOutOfRange{}
      -> ErrorWithoutFlag
    TcRnIllegalWildcardsInConstructor{}
      -> ErrorWithoutFlag
    TcRnIgnoringAnnotations{}
      -> WarningWithoutFlag
    TcRnAnnotationInSafeHaskell
      -> ErrorWithoutFlag
    TcRnInvalidTypeApplication{}
      -> ErrorWithoutFlag
    TcRnTagToEnumMissingValArg
      -> ErrorWithoutFlag
    TcRnTagToEnumUnspecifiedResTy{}
      -> ErrorWithoutFlag
    TcRnTagToEnumResTyNotAnEnum{}
      -> ErrorWithoutFlag
    TcRnArrowIfThenElsePredDependsOnResultTy
      -> ErrorWithoutFlag
    TcRnArrowCommandExpected{}
      -> ErrorWithoutFlag
    TcRnIllegalHsBootFileDecl
      -> ErrorWithoutFlag
    TcRnRecursivePatternSynonym{}
      -> ErrorWithoutFlag
    TcRnPartialTypeSigTyVarMismatch{}
      -> ErrorWithoutFlag
    TcRnPartialTypeSigBadQuantifier{}
      -> ErrorWithoutFlag
    TcRnPolymorphicBinderMissingSig{}
      -> WarningWithFlag Opt_WarnMissingLocalSignatures
    TcRnOverloadedSig{}
      -> ErrorWithoutFlag
    TcRnTupleConstraintInst{}
      -> ErrorWithoutFlag
    TcRnAbstractClassInst{}
      -> ErrorWithoutFlag
    TcRnNoClassInstHead{}
      -> ErrorWithoutFlag
    TcRnUserTypeError{}
      -> ErrorWithoutFlag
    TcRnConstraintInKind{}
      -> ErrorWithoutFlag
    TcRnUnboxedTupleTypeFuncArg{}
      -> ErrorWithoutFlag
    TcRnLinearFuncInKind{}
      -> ErrorWithoutFlag
    TcRnForAllEscapeError{}
      -> ErrorWithoutFlag
    TcRnVDQInTermType{}
      -> ErrorWithoutFlag
    TcRnIllegalEqualConstraints{}
      -> ErrorWithoutFlag
    TcRnBadQuantPredHead{}
      -> ErrorWithoutFlag
    TcRnIllegalTupleConstraint{}
      -> ErrorWithoutFlag
    TcRnNonTypeVarArgInConstraint{}
      -> ErrorWithoutFlag
    TcRnIllegalImplicitParam{}
      -> ErrorWithoutFlag
    TcRnIllegalConstraintSynonymOfKind{}
      -> ErrorWithoutFlag
    TcRnIllegalClassInst{}
      -> ErrorWithoutFlag
    TcRnOversaturatedVisibleKindArg{}
      -> ErrorWithoutFlag
    TcRnBadAssociatedType{}
      -> ErrorWithoutFlag
    TcRnForAllRankErr{}
      -> ErrorWithoutFlag
    TcRnMonomorphicBindings{}
      -> WarningWithFlag Opt_WarnMonomorphism
    TcRnOrphanInstance{}
      -> WarningWithFlag Opt_WarnOrphans
    TcRnFunDepConflict{}
      -> ErrorWithoutFlag
    TcRnDupInstanceDecls{}
      -> ErrorWithoutFlag
    TcRnConflictingFamInstDecls{}
      -> ErrorWithoutFlag
    TcRnFamInstNotInjective{}
      -> ErrorWithoutFlag
    TcRnBangOnUnliftedType{}
      -> WarningWithFlag Opt_WarnRedundantStrictnessFlags
    TcRnMultipleDefaultDeclarations{}
      -> ErrorWithoutFlag
    TcRnBadDefaultType{}
      -> ErrorWithoutFlag
    TcRnPatSynBundledWithNonDataCon{}
      -> ErrorWithoutFlag
    TcRnPatSynBundledWithWrongType{}
      -> ErrorWithoutFlag
    TcRnDupeModuleExport{}
      -> WarningWithFlag Opt_WarnDuplicateExports
    TcRnExportedModNotImported{}
      -> ErrorWithoutFlag
    TcRnNullExportedModule{}
      -> WarningWithFlag Opt_WarnDodgyExports
    TcRnMissingExportList{}
      -> WarningWithFlag Opt_WarnMissingExportList
    TcRnExportHiddenComponents{}
      -> ErrorWithoutFlag
    TcRnDuplicateExport{}
      -> WarningWithFlag Opt_WarnDuplicateExports
    TcRnExportedParentChildMismatch{}
      -> ErrorWithoutFlag
    TcRnConflictingExports{}
      -> ErrorWithoutFlag

  diagnosticHints = \case
    TcRnUnknownMessage m
      -> diagnosticHints m
    TcLevityPolyInType{}
      -> noHints
    TcRnMessageWithInfo _ msg_with_info
      -> case msg_with_info of
           TcRnMessageDetailed _ m -> diagnosticHints m
    TcRnImplicitLift{}
      -> noHints
    TcRnUnusedPatternBinds{}
      -> noHints
    TcRnDodgyImports{}
      -> noHints
    TcRnDodgyExports{}
      -> noHints
    TcRnMissingImportList{}
      -> noHints
    TcRnUnsafeDueToPlugin{}
      -> noHints
    TcRnModMissingRealSrcSpan{}
      -> noHints
    TcRnIdNotExportedFromModuleSig name mod
      -> [SuggestAddToHSigExportList name $ Just mod]
    TcRnIdNotExportedFromLocalSig name
      -> [SuggestAddToHSigExportList name Nothing]
    TcRnShadowedName{}
      -> noHints
    TcRnDuplicateWarningDecls{}
      -> noHints
    TcRnSimplifierTooManyIterations{}
      -> [SuggestIncreaseSimplifierIterations]
    TcRnIllegalPatSynDecl{}
      -> noHints
    TcRnLinearPatSyn{}
      -> noHints
    TcRnEmptyRecordUpdate{}
      -> noHints
    TcRnIllegalFieldPunning{}
      -> [suggestExtension LangExt.NamedFieldPuns]
    TcRnIllegalWildcardsInRecord{}
      -> [suggestExtension LangExt.RecordWildCards]
    TcRnDuplicateFieldName{}
      -> noHints
    TcRnIllegalViewPattern{}
      -> [suggestExtension LangExt.ViewPatterns]
    TcRnCharLiteralOutOfRange{}
      -> noHints
    TcRnIllegalWildcardsInConstructor{}
      -> noHints
    TcRnIgnoringAnnotations{}
      -> noHints
    TcRnAnnotationInSafeHaskell
      -> noHints
    TcRnInvalidTypeApplication{}
      -> noHints
    TcRnTagToEnumMissingValArg
      -> noHints
    TcRnTagToEnumUnspecifiedResTy{}
      -> noHints
    TcRnTagToEnumResTyNotAnEnum{}
      -> noHints
    TcRnArrowIfThenElsePredDependsOnResultTy
      -> noHints
    TcRnArrowCommandExpected{}
      -> noHints
    TcRnIllegalHsBootFileDecl
      -> noHints
    TcRnRecursivePatternSynonym{}
      -> noHints
    TcRnPartialTypeSigTyVarMismatch{}
      -> noHints
    TcRnPartialTypeSigBadQuantifier{}
      -> noHints
    TcRnPolymorphicBinderMissingSig{}
      -> noHints
    TcRnOverloadedSig{}
      -> noHints
    TcRnTupleConstraintInst{}
      -> noHints
    TcRnAbstractClassInst{}
      -> noHints
    TcRnNoClassInstHead{}
      -> noHints
    TcRnUserTypeError{}
      -> noHints
    TcRnConstraintInKind{}
      -> noHints
    TcRnUnboxedTupleTypeFuncArg{}
      -> [suggestExtension LangExt.UnboxedTuples]
    TcRnLinearFuncInKind{}
      -> noHints
    TcRnForAllEscapeError{}
      -> noHints
    TcRnVDQInTermType{}
      -> noHints
    TcRnIllegalEqualConstraints{}
      -> [suggestAnyExtension [LangExt.GADTs, LangExt.TypeFamilies]]
    TcRnBadQuantPredHead{}
      -> noHints
    TcRnIllegalTupleConstraint{}
      -> [suggestExtension LangExt.ConstraintKinds]
    TcRnNonTypeVarArgInConstraint{}
      -> [suggestExtension LangExt.FlexibleContexts]
    TcRnIllegalImplicitParam{}
      -> noHints
    TcRnIllegalConstraintSynonymOfKind{}
      -> [suggestExtension LangExt.ConstraintKinds]
    TcRnIllegalClassInst{}
      -> noHints
    TcRnOversaturatedVisibleKindArg{}
      -> noHints
    TcRnBadAssociatedType{}
      -> noHints
    TcRnForAllRankErr rank _
      -> case rank of
           LimitedRank{}      -> [suggestExtension LangExt.RankNTypes]
           MonoTypeRankZero   -> [suggestExtension LangExt.RankNTypes]
           MonoTypeTyConArg   -> [suggestExtension LangExt.ImpredicativeTypes]
           MonoTypeSynArg     -> [suggestExtension LangExt.LiberalTypeSynonyms]
           MonoTypeConstraint -> [suggestExtension LangExt.QuantifiedConstraints]
           _                  -> noHints
    TcRnMonomorphicBindings bindings
      -> case bindings of
          []     -> noHints
          (x:xs) -> [SuggestAddTypeSignatures $ NamedBindings (x NE.:| xs)]
    TcRnOrphanInstance{}
      -> [SuggestFixOrphanInstance]
    TcRnFunDepConflict{}
      -> noHints
    TcRnDupInstanceDecls{}
      -> noHints
    TcRnConflictingFamInstDecls{}
      -> noHints
    TcRnFamInstNotInjective rea _ _
      -> case rea of
           InjErrRhsBareTyVar{}      -> noHints
           InjErrRhsCannotBeATypeFam -> noHints
           InjErrRhsOverlap          -> noHints
           InjErrCannotInferFromRhs _ _ suggestUndInst
             | YesSuggestUndecidableInstaces <- suggestUndInst
             -> [suggestExtension LangExt.UndecidableInstances]
             | otherwise
             -> noHints
    TcRnBangOnUnliftedType{}
      -> noHints
    TcRnMultipleDefaultDeclarations{}
      -> noHints
    TcRnBadDefaultType{}
      -> noHints
    TcRnPatSynBundledWithNonDataCon{}
      -> noHints
    TcRnPatSynBundledWithWrongType{}
      -> noHints
    TcRnDupeModuleExport{}
      -> noHints
    TcRnExportedModNotImported{}
      -> noHints
    TcRnNullExportedModule{}
      -> noHints
    TcRnMissingExportList{}
      -> noHints
    TcRnExportHiddenComponents{}
      -> noHints
    TcRnDuplicateExport{}
      -> noHints
    TcRnExportedParentChildMismatch{}
      -> noHints
    TcRnConflictingExports{}
      -> noHints

messageWithInfoDiagnosticMessage :: UnitState
                                 -> ErrInfo
                                 -> DecoratedSDoc
                                 -> DecoratedSDoc
messageWithInfoDiagnosticMessage unit_state ErrInfo{..} important =
  let err_info' = map (pprWithUnitState unit_state) [errInfoContext, errInfoSupplementary]
      in (mapDecoratedSDoc (pprWithUnitState unit_state) important) `unionDecoratedSDoc`
         mkDecorated err_info'

dodgy_msg :: (Outputable a, Outputable b) => SDoc -> a -> b -> SDoc
dodgy_msg kind tc ie
  = sep [ text "The" <+> kind <+> text "item"
                     <+> quotes (ppr ie)
                <+> text "suggests that",
          quotes (ppr tc) <+> text "has (in-scope) constructors or class methods,",
          text "but it has none" ]

dodgy_msg_insert :: forall p . IdP (GhcPass p) -> IE (GhcPass p)
dodgy_msg_insert tc = IEThingAll noAnn ii
  where
    ii :: LIEWrappedName (IdP (GhcPass p))
    ii = noLocA (IEName $ noLocA tc)

formatLevPolyErr :: Type  -- representation-polymorphic type
                 -> SDoc
formatLevPolyErr ty
  = hang (text "A representation-polymorphic type is not allowed here:")
       2 (vcat [ text "Type:" <+> pprWithTYPE tidy_ty
               , text "Kind:" <+> pprWithTYPE tidy_ki ])
  where
    (tidy_env, tidy_ty) = tidyOpenType emptyTidyEnv ty
    tidy_ki             = tidyType tidy_env (tcTypeKind ty)

pprLevityPolyInType :: Type -> LevityCheckProvenance -> SDoc
pprLevityPolyInType ty prov =
  let extra = case prov of
        LevityCheckInBinder v
          -> text "In the type of binder" <+> quotes (ppr v)
        LevityCheckInVarType
          -> text "When trying to create a variable of type:" <+> ppr ty
        LevityCheckInWildcardPattern
          -> text "In a wildcard pattern"
        LevityCheckInUnboxedTuplePattern p
          -> text "In the type of an element of an unboxed tuple pattern:" $$ ppr p
        LevityCheckPatSynSig
          -> empty
        LevityCheckCmdStmt
          -> empty -- I (Richard E, Dec '16) have no idea what to say here
        LevityCheckMkCmdEnv id_var
          -> text "In the result of the function" <+> quotes (ppr id_var)
        LevityCheckDoCmd do_block
          -> text "In the do-command:" <+> ppr do_block
        LevityCheckDesugaringCmd cmd
          -> text "When desugaring the command:" <+> ppr cmd
        LevityCheckInCmd body
          -> text "In the command:" <+> ppr body
        LevityCheckInFunUse using
          -> text "In the result of a" <+> quotes (text "using") <+> text "function:" <+> ppr using
        LevityCheckInValidDataCon
          -> empty
        LevityCheckInValidClass
          -> empty
  in formatLevPolyErr ty $$ extra


pprRecordFieldPart :: RecordFieldPart -> SDoc
pprRecordFieldPart = \case
  RecordFieldConstructor{} -> text "construction"
  RecordFieldPattern{}     -> text "pattern"
  RecordFieldUpdate        -> text "update"

pprBindings :: [Name] -> SDoc
pprBindings = pprWithCommas (quotes . ppr)

injectivityErrorHerald :: SDoc
injectivityErrorHerald =
  text "Type family equation violates the family's injectivity annotation."

formatExportItemError :: SDoc -> String -> SDoc
formatExportItemError exportedThing reason =
  hsep [ text "The export item"
       , quotes exportedThing
       , text reason ]