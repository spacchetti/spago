{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Main where

import           Control.Exception        (SomeException, try)
import           Data.Aeson
import           Data.Aeson.Encode.Pretty as JSON
import qualified Data.ByteString.Lazy     as ByteString.Lazy
import qualified Data.List                as List
import qualified Data.Map                 as Map
import           Data.Text                (Text)
import qualified Data.Text                as Text
import qualified Data.Text.Encoding       as Text
import           Data.Version             (showVersion)
import qualified Dhall.Format             as Dhall.Format
import qualified Dhall.JSON               as Dhall.JSON
import qualified Dhall.Pretty             as Dhall.Pretty
import qualified GHC.IO.Encoding
import qualified Paths_spacchetti_cli     as Pcli
import qualified System.Directory         as Dir
import qualified Templates
import qualified Turtle                   as T
import qualified Types

-- | Commands that this program handles
data Command
  -- | # Commands for working with Psc-Package:

  -- | Do the boilerplate of the local project setup to override and add arbitrary packages
  -- | See the Spacchetti docs about this here: https://spacchetti.readthedocs.io/en/latest/local-setup.html
  = LocalSetup Bool
  -- | Do the Ins-Dhall-ation of the local project setup, equivalent to:
  -- | ```sh
  -- | NAME='local'
  -- | TARGET=.psc-package/$NAME/.set/packages.json
  -- | mktree -p .psc-package/$NAME/.set
  -- | dhall-to-json --pretty <<< './packages.dhall' > $TARGET
  -- | echo wrote packages.json to $TARGET
  -- | ```
  | InsDhall
  -- | Deletes the .psc-package folder
  | Clean

  -- | # Commands for working with Spacchetti projects
  -- | Initialize a Spacchetti project
  | InitSpacchetti Bool
  -- | Install dependencies defined in spacchetti.dhall
  | Install
  -- | Get source globs of dependencies in .spacchetti install path
  | Sources
  -- | Build the project paths src/ and test/
  | Build

  -- | Show spacchetti-cli version
  | Version


echo' :: Text -> IO ()
echo' = T.echo . T.unsafeTextToLine

unsafePathToText :: T.FilePath -> Text
unsafePathToText p = case T.toText p of
  Left t  -> t
  Right t -> t


-- | The directory in which spacchetti will put its tempfiles
spacchettiDir :: Text
spacchettiDir = ".spacchetti/"

pscPackageBasePathText :: Text
pscPackageBasePathText = ".psc-package/local/.set/"

pscPackageBasePath :: T.FilePath
pscPackageBasePath = T.fromText pscPackageBasePathText

packagesJsonText :: Text
packagesJsonText = pscPackageBasePathText <> "packages.json"

packagesJsonPath :: T.FilePath
packagesJsonPath = T.fromText packagesJsonText

packagesDhallText :: Text
packagesDhallText = "./packages.dhall"

packagesDhallPath :: T.FilePath
packagesDhallPath = T.fromText packagesDhallText

spacchettiDhallText :: Text
spacchettiDhallText = "spacchetti.dhall"

spacchettiDhallPath :: T.FilePath
spacchettiDhallPath = T.fromText spacchettiDhallText

spacchettiJsonText :: Text
spacchettiJsonText = spacchettiDir <> "spacchetti.json"

spacchettiJsonPath :: T.FilePath
spacchettiJsonPath = T.fromText spacchettiJsonText


insDhall :: IO ()
insDhall = do
  isProject <- T.testfile packagesDhallPath
  T.unless isProject $
    T.die "Missing packages.dhall file. Run `spacchetti local-setup` first."
  T.mktree pscPackageBasePath
  T.touch packagesJsonPath

  res <- try (dhallToJSON packagesDhallPath packagesJsonPath)

  case res of
    Right _ -> do
      T.echo $ T.unsafeTextToLine $ "Wrote packages.json to " <> packagesJsonText
      T.echo "Now you can run `psc-package install`."
    Left (err :: SomeException) ->
      T.die ("Failed to insdhall: " <> Text.pack (show err))

-- | Tries to create the `packages.dhall` file. Fails when the file already exists,
-- | unless `--force` has been used.
makePackagesDhall :: Bool -> Text -> IO ()
makePackagesDhall force command = do
  T.unless force $ do
    hasPackagesDhall <- T.testfile packagesDhallPath
    T.when hasPackagesDhall $ T.die
       $ "Found " <> packagesDhallText <> ": there's already a project here. "
      <> "Run `spacchetti " <> command <> " --force` if you're sure you want to overwrite it."
  T.touch packagesDhallPath
  T.writeTextFile packagesDhallPath Templates.packagesDhall
  Dhall.Format.format Dhall.Pretty.Unicode (Just $ Text.unpack packagesDhallText)

-- | Tries to create the `psc-package.json` file. Existing dependencies are preserved,
-- | unless `--force` has been used.
makePscPackage :: Bool -> IO ()
makePscPackage force = do
  hasPscPackage <- T.testfile pscPackageJsonPath
  if hasPscPackage && not force
    then do
      pscPackage <- T.readTextFile pscPackageJsonPath
      case eitherDecodeStrict $ Text.encodeUtf8 pscPackage of
        Left e -> T.die $ "The existing psc-package.json file is in the wrong format: " <>
          Text.pack e
        Right p -> do
          T.writeTextFile pscPackageJsonPath $
            Templates.encodePscPackage $ p { Types.set = "local", Types.source = "" }
          T.echo "An existing psc-package.json file was found and upgraded to use local package sets."
          T.echo $ "It's possible that some of the existing dependencies are not in the default spacchetti package set."

    else do
      T.touch pscPackageJsonPath
      pwd <- T.pwd
      let projectName = case T.toText $ T.filename pwd of
            Left _  -> "my-project"
            Right n -> n
      T.writeTextFile pscPackageJsonPath $ Templates.pscPackageJson projectName

  where
    pscPackageJsonPath = T.fromText "psc-package.json"

-- | Copies over `spacchetti.dhall` to set up a Spacchetti project
makeSpacchetti :: Bool -> IO ()
makeSpacchetti force = do
  T.unless force $ do
    hasSpacchettiDhall <- T.testfile spacchettiDhallPath
    T.when hasSpacchettiDhall $ T.die
       $ "Found " <> unsafePathToText spacchettiDhallPath <> ": there's already a project here. "
      <> "Run `spacchetti initSpacchetti --force` if you're sure you want to overwrite it."
  T.touch spacchettiDhallPath
  T.writeTextFile spacchettiDhallPath Templates.spacchettiDhall
  Dhall.Format.format Dhall.Pretty.Unicode (Just $ Text.unpack spacchettiDhallText)

localSetup :: Bool -> IO ()
localSetup force = do
  makePackagesDhall force "local-setup"
  makePscPackage force
  T.echo "Set up local Spacchetti packages."
  T.echo "Run `spacchetti insdhall` to generate the package set."

initSpacchetti :: Bool -> IO ()
initSpacchetti force = do
  makePackagesDhall force "init"
  makeSpacchetti force
  T.mktree "src"
  T.mktree "test"
  T.writeTextFile "src/Main.purs" Templates.srcMain
  T.writeTextFile "test/Main.purs" Templates.testMain
  T.writeTextFile ".gitignore" Templates.gitignore
  T.echo "Set up a local Spacchetti project."
  T.echo "Try running `spacchetti install`"

-- | Given a path to a Dhall file and an output path to a JSON file,
--   reads the Dhall, converts it, and writes it as JSON
dhallToJSON :: T.FilePath -> T.FilePath -> IO ()
dhallToJSON inputPath outputPath = do
  let config = JSON.Config
               { JSON.confIndent = JSON.Spaces 2
               , JSON.confCompare = compare
               , JSON.confNumFormat = JSON.Generic
               , JSON.confTrailingNewline = False }

  let encode = JSON.encodePretty' config

  dhall <- T.readTextFile inputPath

  json <- Dhall.JSON.codeToValue Dhall.JSON.NoConversion (unsafePathToText inputPath) dhall

  T.writeTextFile inputPath $ Text.decodeUtf8 $ ByteString.Lazy.toStrict $ encode json

makeSpacchettiJson :: IO ()
makeSpacchettiJson = do
  T.mktree $ T.fromText spacchettiDir
  try (dhallToJSON spacchettiDhallPath spacchettiJsonPath) >>= \case
    Right _ -> pure ()
    Left (err :: SomeException) ->
      T.die $ "making spacchetti.json failed: " <> Text.pack (show err)

readSpacchettiJson :: IO Types.SpacchettiConfig
readSpacchettiJson = do
  spacchettiConfigText <- T.readTextFile spacchettiJsonPath
  case eitherDecodeStrict $ Text.encodeUtf8 spacchettiConfigText of
    Left e -> T.die $ "The generated spacchetti.json was in the wrong format: " <> Text.pack e
    Right config -> return config

install :: IO ()
install = do
  T.echo "generating spacchetti.json"
  makeSpacchettiJson
  spacchettiConfigText <- T.readTextFile spacchettiJsonPath
  config <- readSpacchettiJson
  let deps = getAllDependencies config
  echo' $ "installing " <> Text.pack (show $ List.length deps) <> " dependencies."
  traverse getDep deps
  T.echo "installation complete."

ensureSpacchettiJson :: IO ()
ensureSpacchettiJson = do
  exists <- T.testfile spacchettiJsonPath
  T.unless exists makeSpacchettiJson

getDir :: (Types.PackageName, Types.PackageDefinition) -> Text
getDir
  ( Types.PackageName name
  , Types.PackageDefinition
      { Types.version=version
      , Types.repo=repo
      }
  )
  = spacchettiDir <> name <> "/" <> version

getGlobs :: [(Types.PackageName, Types.PackageDefinition)] -> [Text]
getGlobs = map fn
  where
    fn pair = (getDir pair) <> "/src/**/*.purs"

sources :: IO ()
sources = do
  ensureSpacchettiJson
  config <- readSpacchettiJson
  let
    deps = getAllDependencies config
    globs = getGlobs deps
  _ <- traverse (echo') globs
  pure ()

getDep :: (Types.PackageName, Types.PackageDefinition) -> IO ()
getDep
  pair@
    ( Types.PackageName name
    , Types.PackageDefinition
        { Types.version=version
        , Types.repo=repo
        }
    ) = do
  let dir = getDir pair
  exists <- T.testdir $ T.fromText dir
  if exists
    then do
      echo' $ name <> " already installed."
    else do
      echo' $ "installing " <> name
      T.mktree . T.fromText $ dir
      Dir.withCurrentDirectory (Text.unpack dir) $ do
        let
          cmd = Text.intercalate " && "
            [ "git init"
            , "git remote add origin " <> repo
            , "git fetch origin " <> version
            , "git -c advice.detachedHead=false checkout FETCH_HEAD"
            ]
        code <- T.shell cmd T.empty
        case code of
          T.ExitSuccess -> pure ()
          T.ExitFailure n -> do
            T.rmtree $ T.fromText dir
            T.die ("Failed to install dependency: " <> T.repr n)

getAllDependencies :: Types.SpacchettiConfig -> [(Types.PackageName, Types.PackageDefinition)]
getAllDependencies (Types.SpacchettiConfig {Types.dependencies=deps, Types.packages=pkgs}) =
  Map.toList $ List.foldl' go Map.empty deps
  where
    go acc dep
      | Map.member dep acc = acc
      | otherwise =
          case Map.lookup dep pkgs of
            -- lazy error handling, user gets crash
            Nothing -> error $ "Package " <> show dep <> " was missing from the package set."
            Just x@(Types.PackageDefinition {Types.dependencies=innerDeps}) -> do
              let newAcc = List.foldl' go acc innerDeps
              Map.insert dep x newAcc

surroundQuote :: Text -> Text
surroundQuote y = "\"" <> y <> "\""

build :: IO ()
build = do
  ensureSpacchettiJson
  config <- readSpacchettiJson
  let
    deps = getAllDependencies config
    globs = getGlobs deps <> ["src/**/*.purs", "test/**/*.purs"]
    paths = Text.intercalate " " $ surroundQuote <$> globs
    cmd = "purs compile " <> paths
  code <- T.shell cmd T.empty
  case code of
    T.ExitSuccess -> T.echo "Build succeeded."
    T.ExitFailure n -> do
      T.die ("Failed to build:" <> T.repr n)

printVersion :: IO ()
printVersion =
  T.echo $ T.unsafeTextToLine (Text.pack $ showVersion Pcli.version)

clean :: IO ()
clean = do
  let pscDir = "./.psc-package"
  hasDir <- T.testdir pscDir
  if hasDir
    then do
      T.rmtree pscDir
      T.echo "Packages cache was cleaned."
    else T.echo "Nothing to clean here."

parser :: T.Parser Command
parser
      = LocalSetup <$> localSetup
  T.<|> InsDhall <$ insDhall
  T.<|> Clean <$ clean
  T.<|> Version <$ version
  T.<|> InitSpacchetti <$> initSpacchetti
  T.<|> Install <$ install
  T.<|> Sources <$ sources
  T.<|> Build <$ build
  where
    localSetup =
      T.subcommand
      "local-setup" "run project-local Spacchetti setup" $
      T.switch "force" 'f' "Overwrite any project found in the current directory."
    insDhall = T.subcommand "insdhall" "insdhall the local package set from packages.dhall" $ pure ()
    clean = T.subcommand "clean" "Clean cached packages by deleting the .psc-package folder" $ pure ()
    initSpacchetti =
      T.subcommand
      "init" "initialize a Spacchetti project" $
      T.switch "force" 'f' "Overwrite any project found in the current directory."
    install = T.subcommand "install" "Install a Spacchetti project from spacchetti.dhall" $ pure ()
    sources = T.subcommand "sources" "Get globs of sources of dependencies of a Spacchetti project. Useful for editor plugins." $ pure ()
    build = T.subcommand "build" "Build a Spacchetti project" $ pure ()
    version = T.subcommand "version" "Show spacchetti-cli version" $ pure ()

main :: IO ()
main = do
  GHC.IO.Encoding.setLocaleEncoding GHC.IO.Encoding.utf8
  command <- T.options "Spacchetti CLI" parser
  case command of
    LocalSetup force -> localSetup force
    InsDhall         -> insDhall
    Clean            -> clean
    InitSpacchetti f -> initSpacchetti f
    Install          -> install
    Sources          -> sources
    Build            -> build
    Version          -> printVersion
