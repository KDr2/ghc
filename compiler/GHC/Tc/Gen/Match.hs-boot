module GHC.Tc.Gen.Match where
import GHC.Hs           ( GRHSs, MatchGroup, LHsExpr, Mult )
import GHC.Tc.Utils.TcType( ExpSigmaType, ExpRhoType, ExpPatType )
import GHC.Tc.Types     ( TcM )
import GHC.Tc.Types.Origin  ( UserTypeCtxt )
import GHC.Tc.Types.Evidence  ( HsWrapper )
import GHC.Types.Name    ( Name )
import GHC.Hs.Extension ( GhcRn, GhcTc )

tcGRHSsPat    :: Mult
              -> GRHSs GhcRn (LHsExpr GhcRn)
              -> ExpRhoType
              -> TcM (GRHSs GhcTc (LHsExpr GhcTc))

tcFunBindMatches  :: UserTypeCtxt
                  -> Name
                  -> Mult
                  -> MatchGroup GhcRn (LHsExpr GhcRn)
                  -> [ExpPatType]
                  -> ExpSigmaType
                  -> TcM (HsWrapper, MatchGroup GhcTc (LHsExpr GhcTc))
