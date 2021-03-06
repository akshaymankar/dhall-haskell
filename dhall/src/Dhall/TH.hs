{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | Template Haskell utilities
module Dhall.TH
    ( -- * Template Haskell
      staticDhallExpression
    , makeHaskellTypeFromUnion
    ) where

import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Text.Prettyprint.Doc (Pretty)
import Dhall.Syntax (Expr(..))
import Language.Haskell.TH.Quote (dataToExpQ) -- 7.10 compatibility.

import Language.Haskell.TH.Syntax
    ( Con(..)
    , Dec(..)
    , Exp(..)
    , Q
    , Type(..)
    , Bang(..)
    , SourceStrictness(..)
    , SourceUnpackedness(..)
    )

import qualified Data.Text                               as Text
import qualified Data.Text.Prettyprint.Doc.Render.String as Pretty
import qualified Data.Typeable                           as Typeable
import qualified Dhall
import qualified Dhall.Map
import qualified Dhall.Pretty
import qualified Dhall.Util
import qualified GHC.IO.Encoding
import qualified Numeric.Natural
import qualified System.IO
import qualified Language.Haskell.TH.Syntax              as Syntax

{-| This fully resolves, type checks, and normalizes the expression, so the
    resulting AST is self-contained.

    This can be used to resolve all of an expression’s imports at compile time,
    allowing one to reference Dhall expressions from Haskell without having a
    runtime dependency on the location of Dhall files.

    For example, given a file @".\/Some\/Type.dhall"@ containing

    > < This : Natural | Other : ../Other/Type.dhall >

    ... rather than duplicating the AST manually in a Haskell `Type`, you can
    do:

    > Dhall.Type
    > (\case
    >     UnionLit "This" _ _  -> ...
    >     UnionLit "Other" _ _ -> ...)
    > $(staticDhallExpression "./Some/Type.dhall")

    This would create the Dhall Expr AST from the @".\/Some\/Type.dhall"@ file
    at compile time with all imports resolved, making it easy to keep your Dhall
    configs and Haskell interpreters in sync.
-}
staticDhallExpression :: Text -> Q Exp
staticDhallExpression text = do
    Syntax.runIO (GHC.IO.Encoding.setLocaleEncoding System.IO.utf8)

    expression <- Syntax.runIO (Dhall.inputExpr text)

    dataToExpQ (\a -> liftText <$> Typeable.cast a) expression
  where
    -- A workaround for a problem in TemplateHaskell (see
    -- https://stackoverflow.com/questions/38143464/cant-find-inerface-file-declaration-for-variable)
    liftText = fmap (AppE (VarE 'Text.pack)) . Syntax.lift . Text.unpack

{-| Convert a Dhall type to a Haskell type that does not require any new
    data declarations
-}
toSimpleHaskellType :: Pretty a => Expr s a -> Q Type
toSimpleHaskellType dhallType =
    case dhallType of
        Bool -> do
            return (ConT ''Bool)

        Double -> do
            return (ConT ''Double)

        Integer -> do
            return (ConT ''Integer)

        Natural -> do
            return (ConT ''Numeric.Natural.Natural)

        Text -> do
            return (ConT ''Text)

        App List dhallElementType -> do
            haskellElementType <- toSimpleHaskellType dhallElementType

            return (AppT (ConT ''[]) haskellElementType)

        App Optional dhallElementType -> do
            haskellElementType <- toSimpleHaskellType dhallElementType

            return (AppT (ConT ''Maybe) haskellElementType)

        _ -> do
            let document =
                    mconcat
                    [ "Unsupported simple type\n"
                    , "                                                                                \n"
                    , "Explanation: Not all Dhall alternative types can be converted to Haskell        \n"
                    , "constructor types.  Specifically, only the following simple Dhall types are     \n"
                    , "supported as an alternative type or a field of an alternative type:             \n"
                    , "                                                                                \n"
                    , "• ❰Bool❱                                                                        \n"
                    , "• ❰Double❱                                                                      \n"
                    , "• ❰Integer❱                                                                     \n"
                    , "• ❰Natural❱                                                                     \n"
                    , "• ❰Text❱                                                                        \n"
                    , "• ❰List a❱     (where ❰a❱ is also a simple type)                                \n"
                    , "• ❰Optional a❱ (where ❰a❱ is also a simple type)                                \n"
                    , "                                                                                \n"
                    , "The Haskell datatype generation logic encountered the following complex         \n"
                    , "Dhall type:                                                                     \n"
                    , "                                                                                \n"
                    , " " <> Dhall.Util.insert dhallType <> "\n"
                    , "                                                                                \n"
                    , "... where a simpler type was expected."
                    ]

            let message = Pretty.renderString (Dhall.Pretty.layout document)

            fail message

-- | Convert a Dhall type to the corresponding Haskell constructor type
toConstructor :: Pretty a => (Text, Maybe (Expr s a)) -> Q Con
toConstructor (constructorName, maybeAlternativeType) = do
    let name = Syntax.mkName (Text.unpack constructorName)

    let bang = Bang NoSourceUnpackedness NoSourceStrictness

    case maybeAlternativeType of
        Just (Record kts) -> do
            let process (key, dhallFieldType) = do
                    haskellFieldType <- toSimpleHaskellType dhallFieldType

                    return (Syntax.mkName (Text.unpack key), bang, haskellFieldType)

            varBangTypes <- traverse process (Dhall.Map.toList kts)

            return (RecC name varBangTypes)

        Just dhallAlternativeType -> do
            haskellAlternativeType <- toSimpleHaskellType dhallAlternativeType

            return (NormalC name [ (bang, haskellAlternativeType) ])

        Nothing -> do
            return (NormalC name [])

-- | Generate a Haskell datatype declaration from a Dhall union type where
-- each union alternative corresponds to a Haskell constructor
--
-- This comes in handy if you need to keep a Dhall type and Haskell type in
-- sync.  You make the Dhall type the source of truth and use Template Haskell
-- to generate the matching Haskell type declaration from the Dhall type.
--
-- For example, this Template Haskell splice:
--
-- > Dhall.TH.makeHaskellTypeFromUnion "T" "< A : { x : Bool } | B >"
--
-- ... generates this Haskell code:
--
-- > data T = A {x :: GHC.Types.Bool} | B
--
-- If you are starting from an existing record type that you want to convert to
-- a Haskell type, wrap the record type in a union with one alternative, like
-- this:
--
-- > Dhall.TH.makeHaskellTypeFromUnion "T" "< A : ./recordType.dhall >"
--
-- To add any desired instances (such as `Dhall.FromDhall`/`Dhall.ToDhall`),
-- you can use the `StandaloneDeriving` language extension, like this:
--
-- > {-# LANGUAGE DeriveAnyClass     #-}
-- > {-# LANGUAGE DeriveGeneric      #-}
-- > {-# LANGUAGE OverloadedStrings  #-}
-- > {-# LANGUAGE StandaloneDeriving #-}
-- > {-# LANGUAGE TemplateHaskell    #-}
-- >
-- > Dhall.TH.makeHaskellTypeFromUnion  "T" "< A : { x : Bool } | B >"
-- > 
-- > deriving instance Generic   T
-- > deriving instance FromDhall T
makeHaskellTypeFromUnion
    :: Text
    -- ^ Name of the generated Haskell type
    -> Text
    -- ^ Dhall code that evaluates to a union type
    -> Q [Dec]
makeHaskellTypeFromUnion typeName text = do
    Syntax.runIO (GHC.IO.Encoding.setLocaleEncoding System.IO.utf8)

    expression <- Syntax.runIO (Dhall.inputExpr text)

    case expression of
        Union kts -> do
            let name = Syntax.mkName (Text.unpack typeName)

            constructors <- traverse toConstructor (Dhall.Map.toList kts )

            let declaration = DataD [] name []
                    Nothing
                    constructors []

            return [ declaration ]

        _ -> do
            let document =
                    mconcat
                    [ "Dhall.TH.makeHaskellTypeFromUnion: Unsupported Dhall type\n"
                    , "                                                                                \n"
                    , "Explanation: This function only coverts Dhall union types to Haskell datatype   \n"
                    , "declarations.                                                                   \n"
                    , "                                                                                \n"
                    , "For example, this is a valid Dhall union type that this function would accept:  \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────────────────────────────────┐        \n"
                    , "    │ Dhall.TH.makeHaskellTypeFromUnion \"T\" \"< A : { x : Bool } | B >\" │        \n"
                    , "    └──────────────────────────────────────────────────────────────────┘        \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "... which corresponds to this Haskell type declaration:                         \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────┐                                    \n"
                    , "    │ data T = A {x :: GHC.Types.Bool} | B │                                    \n"
                    , "    └──────────────────────────────────────┘                                    \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "... but the following Dhall type is rejected due to being a bare record type:   \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────────────────────┐                    \n"
                    , "    │ Dhall.TH.makeHaskellTypeFromUnion \"T\" \"{ x : Bool }\" │  Not valid         \n"
                    , "    └──────────────────────────────────────────────────────┘                    \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "If you are starting from a file containing only a record type and you want to   \n"
                    , "generate a Haskell type from that, then wrap the record type in a union with one\n"
                    , "alternative, like this:                                                         \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "    ┌──────────────────────────────────────────────────────────────────┐        \n"
                    , "    │ Dhall.TH.makeHaskellTypeFromUnion \"T\" \"< A : ./recordType.dhall >\" │      \n"
                    , "    └──────────────────────────────────────────────────────────────────┘        \n"
                    , "                                                                                \n"
                    , "                                                                                \n"
                    , "The Haskell datatype generation logic encountered the following Dhall type:     \n"
                    , "                                                                                \n"
                    , " " <> Dhall.Util.insert expression <> "\n"
                    , "                                                                                \n"
                    , "... which is not a union type."
                    ]

            let message = Pretty.renderString (Dhall.Pretty.layout document)

            fail message
