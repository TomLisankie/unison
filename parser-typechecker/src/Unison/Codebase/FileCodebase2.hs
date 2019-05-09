{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Unison.Codebase.FileCodebase2 where

import           Control.Monad                  ( forever )
import           Control.Monad.Error.Class      ( MonadError
                                                , throwError
                                                )
import           UnliftIO                       ( MonadIO
                                                , MonadUnliftIO
                                                , liftIO )
import           UnliftIO.Concurrent            ( forkIO
                                                , killThread
                                                )
import           UnliftIO.STM                   ( atomically )
import qualified Data.Char                     as Char
import           Data.Foldable                  ( traverse_, toList )
import           Data.Functor ((<&>))
import           Data.List.Split                ( splitOn )
import qualified Data.Map                      as Map
import           Data.Maybe                     ( fromMaybe )
import           Data.Set                       ( Set )
import qualified Data.Set                      as Set
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Text.Encoding             ( encodeUtf8
                                                -- , decodeUtf8
                                                )
import           UnliftIO.Directory             ( createDirectoryIfMissing
                                                , doesFileExist
                                                , doesDirectoryExist
                                                , listDirectory
                                                , removeFile
                                                -- , removeDirectoryRecursive
                                                )
import           System.FilePath                ( FilePath
                                                , takeBaseName
                                                , (</>)
                                                )
import           Text.Read                      ( readMaybe )
import qualified Unison.Builtin2               as Builtin
import           Unison.Codebase2               ( Codebase(Codebase) )
import           Unison.Codebase.Causal2        ( Causal
                                                , RawHash(..)
                                                )
import qualified Unison.Codebase.Causal2       as Causal
import           Unison.Codebase.Branch2        ( Branch )
import qualified Unison.Codebase.Branch2       as Branch
import qualified Unison.Codebase.Serialization as S
import qualified Unison.Codebase.Serialization.V1
                                               as V1
import qualified Unison.Codebase.Watch         as Watch
import qualified Unison.Hash                   as Hash
import qualified Unison.Reference              as Reference
import           Unison.Reference               ( Reference )
import qualified Unison.Term                   as Term
import qualified Unison.Util.TQueue            as TQueue
import           Unison.Var                     ( Var )
-- import Debug.Trace

type CodebasePath = FilePath
data Err
  = InvalidBranchFile FilePath String
  | NoBranchHead FilePath
  | CantParseBranchHead FilePath
  | AmbiguouslyTypeAndTerm Reference.Id
  | UnknownTypeOrTerm Reference
  deriving Show

termsDir, typesDir, branchesDir, branchHeadDir :: CodebasePath -> FilePath
termsDir root = root </> "terms"
typesDir root = root </> "types"
branchesDir root = root </> "branches"
branchHeadDir root = branchesDir root </> "head"

termDir, declDir :: CodebasePath -> Reference.Id -> FilePath
termDir root r = termsDir root </> componentId r
declDir root r = typesDir root </> componentId r

builtinDir :: CodebasePath -> Reference -> Maybe FilePath
builtinDir root r@(Reference.Builtin name) =
  if Builtin.isBuiltinTerm r then Just (builtinTermDir root name)
  else if Builtin.isBuiltinType r then Just (builtinTypeDir root name)
  else Nothing
builtinDir _ _ = Nothing

builtinTermDir, builtinTypeDir, watchesDir :: CodebasePath -> Text -> FilePath
builtinTermDir root name = termsDir root </> "_builtin" </> encodeFileName name
builtinTypeDir root name = typesDir root </> "_builtin" </> encodeFileName name
watchesDir root kind = root </> "watches" </> encodeFileName kind


-- https://superuser.com/questions/358855/what-characters-are-safe-in-cross-platform-file-names-for-linux-windows-and-os
encodeFileName :: Text -> FilePath
encodeFileName t = let
  go ('/' : rem) = "$forward-slash$" <> go rem
  go ('\\' : rem) = "$back-slash$" <> go rem
  go (':' : rem) = "$colon$" <> go rem
  go ('*' : rem) = "$star$" <> go rem
  go ('?' : rem) = "$question-mark$" <> go rem
  go ('"' : rem) = "$double-quote$" <> go rem
  go ('<' : rem) = "$less-than$" <> go rem
  go ('>' : rem) = "$greater-than$" <> go rem
  go ('|' : rem) = "$pipe$" <> go rem
  go ('$' : rem) = "$$" <> go rem
  go (c : rem) | not (Char.isPrint c && Char.isAscii c)
                 = "$b58" <> b58 [c] <> "$" <> go rem
               | otherwise = c : go rem
  go [] = []
  b58 = Hash.base58s . Hash.fromBytes . encodeUtf8 . Text.pack
  in if t == "." then "$dot$"
     else if t == ".." then "$dotdot$"
     else go (Text.unpack t)


-- todo: can simplify this if Reference ever distinguishes terms from types
dependentsDir :: (MonadError Err m, MonadIO m)
              => CodebasePath -> Reference -> m FilePath
dependentsDir root r = go r <&> (</> "dependents") where
  go :: (MonadError Err m, MonadIO m) => Reference -> m FilePath
  go r@(Reference.Builtin name) =
    if Builtin.isBuiltinTerm r then pure $ builtinTermDir root name
    else if Builtin.isBuiltinType r then pure $ builtinTypeDir root name
    else throwError $ UnknownTypeOrTerm r
  go r@(Reference.DerivedId id) = do
    isTerm <- doesDirectoryExist (termDir root id)
    isType <- doesDirectoryExist (declDir root id)
    case (isTerm, isType) of
      (True, True) -> throwError $ AmbiguouslyTypeAndTerm id
      (True, False) -> pure $ termDir root id
      (False, True) -> pure $ declDir root id
      (False, False) -> throwError $ UnknownTypeOrTerm r


termPath, typePath, declPath :: CodebasePath -> Reference.Id -> FilePath
termPath path r = termDir path r </> "compiled.ub"
typePath path r = termDir path r </> "type.ub"
declPath path r = declDir path r </> "compiled.ub"

branchPath :: CodebasePath -> Hash.Hash -> FilePath
branchPath root h = branchesDir root </> Hash.base58s h ++ ".ubf"

touchDependentFile :: Reference.Id -> FilePath -> IO ()
touchDependentFile dependent fp = do
  createDirectoryIfMissing True (fp </> "dependents")
  writeFile (fp </> "dependents" </> componentId dependent) ""

-- checks if `path` looks like a unison codebase
minimalCodebaseStructure :: CodebasePath -> [FilePath]
minimalCodebaseStructure root =
  [ termsDir root
  , typesDir root
  , branchesDir root
  , branchHeadDir root
  ]

-- checks if a minimal codebase structure exists at `path`
exists :: CodebasePath -> IO Bool
exists root =
  all id <$> traverse doesDirectoryExist (minimalCodebaseStructure root)

-- creates a minimal codebase structure at `path`
initialize :: CodebasePath -> IO ()
initialize path =
  traverse_ (createDirectoryIfMissing True) (minimalCodebaseStructure path)

getRootBranch
  :: (MonadIO m, MonadError Err m) => CodebasePath -> m (Branch m)
getRootBranch root = do
  (liftIO $ listDirectory (branchHeadDir root)) >>= \case
    [] -> throwError $ NoBranchHead (branchHeadDir root)
    [single] -> case Hash.fromBase58 (Text.pack single) of
      Nothing -> throwError $ CantParseBranchHead single
      Just h -> branchFromFiles root (RawHash h)
    _conflict ->
      -- todo: might want a richer return type that reflects these merges
      error "todo; load all and merge?"
  where
  branchFromFiles :: (MonadIO m, MonadError Err m)
                  => FilePath -> Branch.Hash -> m (Branch m)
  branchFromFiles rootDir rootHash =
    Branch.read (deserializeRawBranch rootDir) rootHash

  deserializeRawBranch
    :: (MonadIO m, MonadError Err m)
    => CodebasePath
    -> Causal.Deserialize m Branch.Raw Branch.Raw
  deserializeRawBranch root (RawHash h) = do
    let ubf = branchPath root h
    liftIO (S.getFromFile' (V1.getCausal0 V1.getRawBranch) ubf) >>= \case
      Left err -> throwError $ InvalidBranchFile ubf err
      Right c0 -> pure c0

putRootBranch
  :: (MonadIO m, MonadError Err m) => CodebasePath -> Branch m -> m ()
putRootBranch root b = do
  Branch.sync hashExists (serializeRawBranch root) b
  updateCausalHead (branchHeadDir root) (Branch._history b)
  where
  hashExists :: MonadIO m => Branch.Hash -> m Bool
  hashExists (RawHash h) = liftIO $ doesFileExist (branchPath root h)
  serializeRawBranch
    :: (MonadIO m)
    => CodebasePath
    -> Causal.Serialize m Branch.Raw Branch.Raw
  serializeRawBranch root (RawHash h) rc = liftIO $
    S.putWithParentDirs
      (V1.putRawCausal V1.putRawBranch) (branchPath root h) rc

-- `headDir` is like ".unison/branches/head", or ".unison/edits/head";
-- not ".unison"
updateCausalHead :: MonadIO m => FilePath -> Causal n h e -> m ()
updateCausalHead headDir c = do
  let (RawHash h) = Causal.currentHash c
  -- delete existing heads
  liftIO $ listDirectory headDir >>= traverse_ removeFile
  -- write new head
  liftIO $ writeFile (headDir </> Hash.base58s h) ""

-- decodeBuiltinName :: FilePath -> Maybe Text
-- decodeBuiltinName p =
--   decodeUtf8 . Hash.toBytes <$> Hash.fromBase58 (Text.pack p)

componentId :: Reference.Id -> String
componentId (Reference.Id h 0 1) = Hash.base58s h
componentId (Reference.Id h i n) =
  Hash.base58s h <> "-" <> show i <> "-" <> show n

-- todo: this is base58-i-n ?
parseHash :: String -> Maybe Reference.Id
parseHash s = case splitOn "-" s of
  [h]       -> makeId h 0 1
  [h, i, n] -> do
    x <- readMaybe i
    y <- readMaybe n
    makeId h x y
  _ -> Nothing
 where
  makeId h i n = (\x -> Reference.Id x i n) <$> Hash.fromBase58 (Text.pack h)

-- builds a `Codebase IO v a`, given serializers for `v` and `a`
codebase1
  :: (MonadError Err m, MonadUnliftIO m, Var v)
  => a -> S.Format v -> S.Format a -> CodebasePath -> Codebase m v a
codebase1 builtinTypeAnnotation (S.Format getV putV) (S.Format getA putA) path =
  Codebase getTerm
           getTypeOfTerm
           getDecl
           putTerm
           putDecl
           (getRootBranch path)
           (putRootBranch path)
           (branchHeadUpdates path)
           dependents
  where
    getTerm h = liftIO $ S.getFromFile (V1.getTerm getV getA) (termPath path h)
    putTerm h e typ = liftIO $ do
      S.putWithParentDirs (V1.putTerm putV putA) (termPath path h) e
      S.putWithParentDirs (V1.putType putV putA) (typePath path h) typ
      let declDependencies :: Set Reference
          declDependencies = Term.referencedDataDeclarations e
            <> Term.referencedEffectDeclarations e
      -- Add the term as a dependent of its dependencies
      let err = "FileCodebase.putTerm found reference to unknown builtin."
          deps = Term.dependencies' e
      traverse_
        (touchDependentFile h  . fromMaybe (error err) . builtinDir path)
        [ r | r@(Reference.Builtin _) <- Set.toList $ deps]
      traverse_ (touchDependentFile h . termDir path)
        $ [ r | Reference.DerivedId r <- Set.toList $ Term.dependencies' e ]
      traverse_ (touchDependentFile h . declDir path)
        $ [ r | Reference.DerivedId r <- Set.toList declDependencies ]
    getTypeOfTerm r = liftIO $ case r of
      Reference.Builtin _ -> pure $
        fmap (const builtinTypeAnnotation) <$> Map.lookup r Builtin.termRefTypes
      Reference.DerivedId h ->
        S.getFromFile (V1.getType getV getA) (typePath path h)
    getDecl h = liftIO $ S.getFromFile
      (V1.getEither (V1.getEffectDeclaration getV getA)
                    (V1.getDataDeclaration getV getA)
      )
      (declPath path h)
    putDecl h decl = liftIO $ S.putWithParentDirs
      (V1.putEither (V1.putEffectDeclaration putV putA)
                    (V1.putDataDeclaration putV putA)
      )
      (declPath path h)
      decl

    dependents :: (MonadError Err m, MonadIO m) =>
                  Reference -> m (Set Reference.Id)
    dependents r = do
      d <- dependentsDir path r
      e <- doesDirectoryExist d
      if e then do
        ls <- listDirectory d
        pure . Set.fromList $ ls >>= (toList . parseHash)
      else pure Set.empty

-- watches in `branchHeadDir root` for externally deposited heads;
-- parse them, and return them
branchHeadUpdates :: (MonadError Err m, MonadUnliftIO m)
                  => CodebasePath -> m (m (), m (Set Hash.Hash))
branchHeadUpdates root = do
  branchHeadChanges      <- TQueue.newIO
  (cancelWatch, watcher) <- Watch.watchDirectory' (branchHeadDir root)
--  -- add .ubf file changes to intermediate queue
  watcher1               <- forkIO $ do
    forever $ do
      -- Q: what does watcher return on a file deletion?
      -- A: nothing
      (filePath, _) <- watcher
      case hashFromFilePath filePath of
        Nothing -> throwError $ CantParseBranchHead filePath
        Just h -> atomically . TQueue.enqueue branchHeadChanges $ h
  -- smooth out intermediate queue
  pure
    $ ( cancelWatch >> killThread watcher1
      , Set.fromList <$> Watch.collectUntilPause branchHeadChanges 400000
      )

hashFromFilePath :: FilePath -> Maybe Hash.Hash
hashFromFilePath = Hash.fromBase58 . Text.pack . takeBaseName