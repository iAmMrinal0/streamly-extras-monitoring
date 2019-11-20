{-# LANGUAGE ExplicitForAll   #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards  #-}

module Streamly.Extra.Metrics where

import           BasicPrelude                      (tshow)
import           Control.Monad                     (void, when)
import           Control.Monad.IO.Class            (MonadIO)
import           Control.Monad.Reader              (MonadReader)
import           Data.Bifunctor                    (first)
import           Data.Functor                      (($>))
import           Data.Maybe                        (fromMaybe, isJust)
import           Data.Text                         (Text)
import           Network.Wai.Handler.Warp          (run)
import qualified Network.Wai.Middleware.Prometheus as PM
import           Prelude                           hiding (log)
import qualified Prometheus                        as P
import           Streamly                          (IsStream, MonadAsync)
import qualified Streamly.Extra                    as SE
import           Streamly.Extra.Logging            (info, metricsInfo)
import           Streamly.Internal.Data.Fold       (Fold (..))
import qualified Streamly.Prelude                  as SP

type MetricName = Text

type MetricHelp = Text

-- class P.MonadMonitor m => MonadMonitor m
register :: MonadIO m => Metric s -> m s
register (Metric s) = P.register s

registerIO :: MonadIO m => m (Metric s) -> m s
registerIO mMetric = mMetric >>= register

--
-- Counter
--
type Counter = P.Counter

-- makes a counter
mkCounter :: MetricName -> MetricHelp -> Metric Counter
mkCounter name = Metric . P.counter . P.Info name

-- makes and registers a counter
-- gives you `m Counter` and not `Metric Counter`
-- use this if you dont want `Metric Counter` in future, otherwise use `mkGauge`
mkRegCounter :: MonadIO m => MetricName -> MetricHelp -> m Counter
mkRegCounter name = register . mkCounter name

getCounter :: MonadIO m => Counter -> m Double
getCounter = P.getCounter

incCounter :: P.MonadMonitor m => Counter -> m ()
incCounter = P.incCounter

-- returns the success status of the add operation
addCounter :: P.MonadMonitor m => Counter -> Double -> m Bool
addCounter = P.addCounter

--
-- Gauge
--
type Gauge = P.Gauge

-- makes a gauge
mkGauge :: MetricName -> MetricHelp -> Metric Gauge
mkGauge name = Metric . P.gauge . P.Info name

-- makes and registers a gauge
-- gives you `m Gauge` and not `Metric Gauge`
-- use this if you dont want `Metric Gauge` in future, otherwise use `mkGauge`
mkRegGauge :: MonadIO m => MetricName -> MetricHelp -> m Gauge
mkRegGauge name = register . mkGauge name

getGauge :: MonadIO m => Gauge -> m Double
getGauge = P.getGauge

incGauge :: P.MonadMonitor m => Gauge -> m ()
incGauge = P.incGauge

addGauge :: P.MonadMonitor m => Gauge -> Double -> m ()
addGauge = P.addGauge

setGauge :: (P.MonadMonitor m) => Gauge -> Double -> m ()
setGauge = P.setGauge

subGauge :: P.MonadMonitor m => Gauge -> Double -> m ()
subGauge = P.subGauge

decGauge :: P.MonadMonitor m => Gauge -> m ()
decGauge = P.decGauge

--
-- Vector
--
-- class P.Label l => Label l
type Vector = P.Vector

-- makes a vector
mkVector :: P.Label l => l -> Metric s -> Metric (Vector l s)
mkVector label (Metric s) = Metric . P.vector label $ s

-- makes and registers a vector
mkRegVector :: (MonadIO m, P.Label l) => l -> Metric a -> m (Vector l a)
mkRegVector label = register . mkVector label

withLabel ::
     (P.Label l, P.MonadMonitor m) => Vector l s -> l -> (s -> IO ()) -> m ()
withLabel = P.withLabel

removeLabel :: (P.Label l, P.MonadMonitor m) => Vector l s -> l -> m ()
removeLabel = P.removeLabel

clearLabels :: (P.Label l, P.MonadMonitor m) => Vector l s -> m ()
clearLabels = P.clearLabels

getVectorWith :: Vector l s -> (s -> IO a) -> IO [(l, a)]
getVectorWith = P.getVectorWith

--
-- Metric
--
newtype Metric s =
  Metric (P.Metric s)

type MaybeUpdateFn = Maybe (Double -> Double)

data MetricDetails =
  MetricDetails
    { counters :: [(Counter, MaybeUpdateFn)]
    , gauges   :: [(Gauge, MaybeUpdateFn)]
    }

instance Eq MetricDetails where
  _ == _ = False

instance Ord MetricDetails where
  _ <= _ = False

-- run this inside a forkIO
initMetricsServer :: Int -> IO ()
initMetricsServer port = do
  info metricsInfo $
    "Starting metrics server at http://localhost:" <> tshow port <> "/"
  run port (PM.prometheus PM.def PM.metricsApp)

--
-- Metrics Logger
--
data LoggerDetails =
  LoggerDetails
    { label        :: Text
    , tag          :: Text
    , unit         :: Text
    , action       :: Text
    , intervalSecs :: Double
    , log          :: (Bool, MaybeUpdateFn)
    , metrics      :: MetricDetails
    }

instance Eq LoggerDetails where
  _ == _ = False

instance Ord LoggerDetails where
  _ <= _ = False

defaultLoggerDetails :: LoggerDetails
defaultLoggerDetails =
  LoggerDetails
    { label = "defaultLabel"
    , tag = "defaultTag"
    , unit = "defaultUnit"
    , action = "defaultAction"
    , intervalSecs = 1.0
    , log = (True, Nothing)
    , metrics = MetricDetails {counters = [], gauges = []}
    }

data M
  = C Counter
  | G Gauge

-- gauges are set with rate/sec
streamlyInfoLogger :: SE.Logger LoggerDetails
streamlyInfoLogger LoggerDetails {..} _ n = do
  mapM_ (update intervalSecs n') (first C <$> counters metrics)
  mapM_ (update intervalSecs n') (first G <$> gauges metrics)
  let (shouldLog, maybeOp) = log
   in when shouldLog $
           info label $
             tag <> " " <> action <> " at the rate of " <>
             tshow (fromMaybe id maybeOp n' / intervalSecs) <>
             " " <>
             unit <>
             "/sec"
  where
    n' = fromIntegral n
    update timeInterval val (metric, maybeOp) = do
      let val' = fromMaybe id maybeOp val
          ratePerSec = val' / timeInterval
      case metric of
        C c -> void $ addCounter c val'
        G g -> setGauge g ratePerSec

--
-- Streamly Metrics
--
-- `withRateGauge`, by its nature, outputs an infinite stream even if the input stream is finite.
-- This function outputs a finite stream if the input stream is finite.
finiteWithRateGauge ::
     ( IsStream t
     , MonadIO m
     , MonadAsync m
     , MonadReader (SE.LoggerConfig tag) (t m)
     , Semigroup (t m (Maybe b))
     , Ord tag
     )
  => tag
  -> t m b
  -> t m b
finiteWithRateGauge logger s =
  SP.mapMaybe id $
  SP.takeWhile isJust $ SE.withRateGauge logger $ (Just <$> s) <> pure Nothing

-- Does @action at @interval and returns the stream as is
doAt :: (Monad m, IsStream t) => Int -> (a -> m ()) -> t m a -> t m a
doAt interval action = SP.tap (Fold step begin end)
  where
    step 0 a = action a $> interval
    step n _ = pure (n - 1)
    begin = pure interval
    end = const (pure ())
