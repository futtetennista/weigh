{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}

-- | Framework for seeing how much a function allocates.
--
-- Example:
--
-- @
-- import Weigh
-- main =
--   mainWith (do func "integers count 0" count 0
--                func "integers count 1" count 1
--                func "integers count 2" count 2
--                func "integers count 3" count 3
--                func "integers count 10" count 10
--                func "integers count 100" count 100)
--   where count :: Integer -> ()
--         count 0 = ()
--         count a = count (a - 1)
-- @

module Weigh
  (-- * Main entry points
   mainWith
  ,weighResults
  -- * Configuration
  ,setColumns
  ,Column(..)
  -- * Simple combinators
  ,func
  ,io
  ,value
  ,action
  -- * Validating combinators
  ,validateAction
  ,validateFunc
  -- * Validators
  ,maxAllocs
  -- * Types
  ,Weigh
  ,Weight(..)
  -- * Handy utilities
  ,commas
  -- * Internals
  ,weighDispatch
  ,weighFunc
  ,weighAction
  )
  where

import Control.Applicative
import Control.Arrow (first, second)
import Control.DeepSeq
import Control.Monad.State (State, execState, modify, unless)
import Data.List
import Data.List.Split
import Data.Maybe (mapMaybe)
import GHC.Int
import GHC.Stats
import Prelude
import System.Environment
import System.Exit
import System.IO
import System.IO.Temp
import System.Mem
import System.Process
import Text.Printf
import Weigh.GHCStats

--------------------------------------------------------------------------------
-- Types

-- | Table column.
data Column = Case | Allocated | GCs| Live | Check | Max
  deriving (Show, Eq, Enum)

-- | Weigh configuration.
data Config = Config {configColumns :: [Column]}
  deriving (Show)

-- | Weigh specification monad.
newtype Weigh a =
  Weigh {runWeigh :: State (Config, [(String,Action)]) a}
  deriving (Monad,Functor,Applicative)

-- | How much a computation weighed in at.
data Weight =
  Weight {weightLabel :: !String
         ,weightAllocatedBytes :: !Int64
         ,weightGCs :: !Int64
         ,weightLiveBytes :: !Int64
         ,weightMaxBytes :: !Int64
         }
  deriving (Read,Show)

-- | An action to run.
data Action =
  forall a b. (NFData a) =>
  Action {_actionRun :: !(Either (b -> IO a) (b -> a))
         ,_actionArg :: !b
         ,actionCheck :: Weight -> Maybe String}

--------------------------------------------------------------------------------
-- Main-runners

-- | Just run the measuring and print a report. Uses 'weighResults'.
mainWith :: Weigh a -> IO ()
mainWith m =
  do (results, config) <- weighResults m
     unless (null results)
            (do putStrLn ""
                putStrLn (report config results))
     case mapMaybe (\(w,r) ->
                      do msg <- r
                         return (w,msg))
                   results of
       [] -> return ()
       errors ->
         do putStrLn "\nCheck problems:"
            mapM_ (\(w,r) -> putStrLn ("  " ++ weightLabel w ++ "\n    " ++ r)) errors
            exitWith (ExitFailure (-1))

-- | Run the measuring and return all the results, each one may have
-- an error.
weighResults
  :: Weigh a -> IO ([(Weight,Maybe String)], Config)
weighResults m = do
  args <- getArgs
  let (config, cases) =
        execState (runWeigh m) (defaultConfig, [])
  result <- weighDispatch args cases
  case result of
    Nothing -> return ([], config)
    Just weights ->
      return
        ( map
            (\w ->
               case lookup (weightLabel w) cases of
                 Nothing -> (w, Nothing)
                 Just a -> (w, actionCheck a w))
            weights
        , config)

--------------------------------------------------------------------------------
-- User DSL

-- | Default columns to display.
defaultColumns :: [Column]
defaultColumns = [Case, Allocated, GCs]

-- | Default config.
defaultConfig :: Config
defaultConfig = Config {configColumns = defaultColumns}

-- | Set the config. Default is: 'defaultConfig'.
setColumns :: [Column] -> Weigh ()
setColumns cs = Weigh (modify (first (\c -> c {configColumns = cs})))

-- | Weigh a function applied to an argument.
--
-- Implemented in terms of 'validateFunc'.
func :: (NFData a)
     => String   -- ^ Name of the case.
     -> (b -> a) -- ^ Function that does some action to measure.
     -> b        -- ^ Argument to that function.
     -> Weigh ()
func name !f !x = validateFunc name f x (const Nothing)

-- | Weigh an action applied to an argument.
--
-- Implemented in terms of 'validateAction'.
io :: (NFData a)
   => String      -- ^ Name of the case.
   -> (b -> IO a) -- ^ Aciton that does some IO to measure.
   -> b           -- ^ Argument to that function.
   -> Weigh ()
io name !f !x = validateAction name f x (const Nothing)

-- | Weigh a value.
--
-- Implemented in terms of 'action'.
value :: NFData a
      => String -- ^ Name for the value.
      -> a      -- ^ The value to measure.
      -> Weigh ()
value name !v = func name id v

-- | Weigh an IO action.
--
-- Implemented in terms of 'validateAction'.
action :: NFData a
       => String -- ^ Name for the value.
       -> IO a   -- ^ The action to measure.
       -> Weigh ()
action name !m = io name (const m) ()

-- | Make a validator that set sthe maximum allocations.
maxAllocs :: Int64 -- ^ The upper bound.
          -> (Weight -> Maybe String)
maxAllocs n =
  \w ->
    if weightAllocatedBytes w > n
       then Just ("Allocated bytes exceeds " ++
                  commas n ++ ": " ++ commas (weightAllocatedBytes w))
       else Nothing

-- | Weigh an IO action, validating the result.
validateAction :: (NFData a)
               => String -- ^ Name of the action.
               -> (b -> IO a) -- ^ The function which performs some IO.
               -> b -- ^ Argument to the function. Doesn't have to be forced.
               -> (Weight -> Maybe String) -- ^ A validating function, returns maybe an error.
               -> Weigh ()
validateAction name !m !arg !validate =
  tellAction [(name,Action (Left m) arg validate)]

-- | Weigh a function, validating the result
validateFunc :: (NFData a)
             => String -- ^ Name of the function.
             -> (b -> a) -- ^ The function which calculates something.
             -> b -- ^ Argument to the function. Doesn't have to be forced.
             -> (Weight -> Maybe String) -- ^ A validating function, returns maybe an error.
             -> Weigh ()
validateFunc name !f !x !validate =
  tellAction [(name,Action (Right f) x validate)]

-- | Write out an action.
tellAction :: [(String, Action)] -> Weigh ()
tellAction x = Weigh (modify (second ( ++ x)))

--------------------------------------------------------------------------------
-- Internal measuring actions

-- | Weigh a set of actions. The value of the actions are forced
-- completely to ensure they are fully allocated.
weighDispatch :: [String] -- ^ Program arguments.
              -> [(String,Action)] -- ^ Weigh name:action mapping.
              -> IO (Maybe [Weight])
weighDispatch args cases =
  case args of
    ("--case":label:fp:_) ->
      let !_ = force fp
      in case lookup label (deepseq (map fst cases) cases) of
           Nothing -> error "No such case!"
           Just act -> do
             case act of
               Action !run arg _ -> do
                 (bytes, gcs, liveBytes, maxByte) <-
                   case run of
                     Right f -> weighFunc f arg
                     Left m -> weighAction m arg
                 writeFile
                   fp
                   (show
                      (Weight
                       { weightLabel = label
                       , weightAllocatedBytes = bytes
                       , weightGCs = gcs
                       , weightLiveBytes = liveBytes
                       , weightMaxBytes = maxByte
                       }))
             return Nothing
    _
      | names == nub names -> fmap Just (mapM (fork . fst) cases)
      | otherwise -> error "Non-unique names specified for things to measure."
      where names = map fst cases

-- | Fork a case and run it.
fork :: String -- ^ Label for the case.
     -> IO Weight
fork label =
  withSystemTempFile
    "weigh"
    (\fp h -> do
       hClose h
       me <- getExecutablePath
       (exit, _, err) <-
         readProcessWithExitCode
           me
           ["--case", label, fp, "+RTS", "-T", "-RTS"]
           ""
       case exit of
         ExitFailure {} ->
           error ("Error in case (" ++ show label ++ "):\n  " ++ err)
         ExitSuccess ->
           do out <- readFile fp
              case reads out of
                [(!r, _)] -> return r
                _ ->
                  error
                    (concat
                       [ "Malformed output from subprocess. Weigh"
                       , " (currently) communicates with its sub-"
                       , "processes via a temporary file."
                       ]))

-- | Weigh a pure function. This function is heavily documented inside.
weighFunc
  :: (NFData a)
  => (b -> a)         -- ^ A function whose memory use we want to measure.
  -> b                -- ^ Argument to the function. Doesn't have to be forced.
  -> IO (Int64,Int64,Int64,Int64) -- ^ Bytes allocated and garbage collections.
weighFunc run !arg =
  do performGC
     -- The above forces getGCStats data to be generated NOW.
     !bootupStats <- getGCStats
     -- We need the above to subtract "program startup" overhead. This
     -- operation itself adds n bytes for the size of GCStats, but we
     -- subtract again that later.
     let !_ = force (run arg)
     performGC
     -- The above forces getGCStats data to be generated NOW.
     !actionStats <- getGCStats
     let reflectionGCs = 1 -- We performed an additional GC.
         actionBytes =
           (bytesAllocated actionStats - bytesAllocated bootupStats) -
           -- We subtract the size of "bootupStats", which will be
           -- included after we did the performGC.
           ghcStatsSizeInBytes
         actionGCs = numGcs actionStats - numGcs bootupStats - reflectionGCs
         -- If overheadBytes is too large, we conservatively just
         -- return zero. It's not perfect, but this library is for
         -- measuring large quantities anyway.
         actualBytes = max 0 actionBytes
         liveBytes = max 0 (currentBytesUsed actionStats -
                            currentBytesUsed bootupStats)
         maxBytes = max 0 (maxBytesUsed actionStats - maxBytesUsed bootupStats)
     return (actualBytes,actionGCs,liveBytes, maxBytes)

-- | Weigh a pure function. This function is heavily documented inside.
weighAction
  :: (NFData a)
  => (b -> IO a)      -- ^ A function whose memory use we want to measure.
  -> b                -- ^ Argument to the function. Doesn't have to be forced.
  -> IO (Int64,Int64,Int64,Int64) -- ^ Bytes allocated and garbage collections.
weighAction run !arg =
  do performGC
     -- The above forces getGCStats data to be generated NOW.
     !bootupStats <- getGCStats
     -- We need the above to subtract "program startup" overhead. This
     -- operation itself adds n bytes for the size of GCStats, but we
     -- subtract again that later.
     !_ <- fmap force (run arg)
     performGC
     -- The above forces getGCStats data to be generated NOW.
     !actionStats <- getGCStats
     let reflectionGCs = 1 -- We performed an additional GC.
         actionBytes =
           (bytesAllocated actionStats - bytesAllocated bootupStats) -
           -- We subtract the size of "bootupStats", which will be
           -- included after we did the performGC.
           ghcStatsSizeInBytes
         actionGCs = numGcs actionStats - numGcs bootupStats - reflectionGCs
         -- If overheadBytes is too large, we conservatively just
         -- return zero. It's not perfect, but this library is for
         -- measuring large quantities anyway.
         actualBytes = max 0 actionBytes
         liveBytes = max 0 (currentBytesUsed actionStats -
                            currentBytesUsed bootupStats)
         maxBytes = max 0 (maxBytesUsed actionStats - maxBytesUsed bootupStats)
     return (actualBytes,actionGCs,liveBytes, maxBytes)

--------------------------------------------------------------------------------
-- Formatting functions

-- | Make a report of the weights.
report :: Config -> [(Weight,Maybe String)] -> String
report config = tablize . (select headings :) . map (select . toRow)
  where
    select row = mapMaybe (\name -> lookup name row) (configColumns config)
    headings =
      [ (Case, (True, "Case"))
      , (Allocated, (False, "Allocated"))
      , (GCs, (False, "GCs"))
      , (Live, (False, "Live"))
      , (Check, (True, "Check"))
      , (Max, (False, "Max"))
      ]
    toRow (w, err) =
      [ (Case, (True, weightLabel w))
      , (Allocated, (False, commas (weightAllocatedBytes w)))
      , (GCs, (False, commas (weightGCs w)))
      , (Live, (False, commas (weightLiveBytes w)))
      , (Max, (False, commas (weightMaxBytes w)))
      , ( Check
        , ( True
          , case err of
              Nothing -> "OK"
              Just {} -> "INVALID"))
      ]

-- | Make a table out of a list of rows.
tablize :: [[(Bool,String)]] -> String
tablize xs =
  intercalate "\n"
              (map (intercalate "  " . map fill . zip [0 ..]) xs)
  where fill (x',(left',text')) = printf ("%" ++ direction ++ show width ++ "s") text'
          where direction = if left'
                               then "-"
                               else ""
                width = maximum (map (length . snd . (!! x')) xs)

-- | Formatting an integral number to 1,000,000, etc.
commas :: (Num a,Integral a,Show a) => a -> String
commas = reverse . intercalate "," . chunksOf 3 . reverse . show
