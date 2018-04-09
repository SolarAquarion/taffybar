{-# LANGUAGE ScopedTypeVariables, ExistentialQuantification, RankNTypes, FlexibleContexts, MonoLocalBinds #-}
-----------------------------------------------------------------------------
-- |
-- Module      : System.Taffybar.Context
-- Copyright   : (c) Ivan A. Malison
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : Ivan A. Malison
-- Stability   : unstable
-- Portability : unportable
-----------------------------------------------------------------------------

module System.Taffybar.Context where

import           Control.Concurrent (forkIO)
import qualified Control.Concurrent.MVar as MV
import           Control.Exception.Enclosed (catchAny)
import           Control.Monad
import           Control.Monad.Base
import           Control.Monad.Trans
import           Control.Monad.Trans.Reader
import           Data.Bits
import           Data.Data
import qualified Data.Map as M
import           Data.Unique
import           System.Information.SafeX11
import           System.Information.X11DesktopInfo
import           Unsafe.Coerce

type Taffy m v = (MonadBase IO m) => ReaderT Context m v
type Listener = Event -> Taffy IO ()
type SubscriptionList = [(Unique, Listener)]
data Value = forall t. Typeable t => Value t

fromValue :: forall t. Typeable t => Value -> Maybe t
fromValue (Value v) =
  if typeOf v == typeRep (Proxy :: Proxy t) then
    Just $ unsafeCoerce v
  else
    Nothing

data Context = Context
  { x11ContextVar :: MV.MVar X11Context
  , listeners :: MV.MVar SubscriptionList
  , contextState :: MV.MVar (M.Map TypeRep Value)
  }

buildEmptyContext :: IO Context
buildEmptyContext = do
  listenersVar <- MV.newMVar []
  state <- MV.newMVar M.empty
  ctx <- getDefaultCtx
  x11Context <- MV.newMVar ctx
  let context = Context
                { x11ContextVar = x11Context
                , listeners = listenersVar
                , contextState = state
                }
  _ <- forkIO $ runReaderT startX11EventHandler context
  return context

asksContextVar :: (r -> MV.MVar b) -> ReaderT r IO b
asksContextVar getter = asks getter >>= lift . MV.readMVar

runX11 :: ReaderT X11Context IO b -> ReaderT Context IO b
runX11 action =
  asksContextVar x11ContextVar >>= lift . runReaderT action

getState :: forall t. Typeable t => Taffy IO (Maybe t)
getState = do
  stateMap <- asksContextVar contextState
  let maybeValue = M.lookup (typeOf (undefined :: t)) stateMap
  return $ maybeValue >>= fromValue

putState :: Typeable t => t -> Taffy IO ()
putState v = do
  contextVar <- asks contextState
  lift $ MV.modifyMVar_ contextVar $ return . M.insert (typeOf v) (Value v)

liftReader ::
  Monad m => (m1 a -> m b) -> ReaderT r m1 a -> ReaderT r m b
liftReader modifier action =
  ask >>= lift . modifier . runReaderT action

taffyFork :: ReaderT r IO () -> ReaderT r IO ()
taffyFork = void . liftReader forkIO

startX11EventHandler :: Taffy IO ()
startX11EventHandler = taffyFork $ do
  (X11Context d w) <- asksContextVar x11ContextVar
  c <- ask
  lift $ do
    selectInput d w $ propertyChangeMask .|. substructureNotifyMask
    allocaXEvent $ \e -> forever $ do
      event <- nextEvent d e >> getEvent e
      case event of
        MapNotifyEvent { ev_window = window } ->
          selectInput d window propertyChangeMask
        _ -> return ()
      runReaderT (handleX11Event event) c

subscribeToAll :: Listener -> Taffy IO Unique
subscribeToAll listener = do
  identifier <- lift newUnique
  listenersVar <- asks listeners
  let
    -- This type annotation probably has something to do with the warnings that
    -- occur without MonoLocalBinds, but it still seems to be necessary
    addListener :: SubscriptionList -> SubscriptionList
    addListener = ((identifier, listener):)
  lift $ MV.modifyMVar_ listenersVar (return . addListener)
  return identifier

subscribeToEvents :: [String] -> Listener -> Taffy IO Unique
subscribeToEvents eventNames listener = do
  eventAtoms <- mapM (runX11 . getAtom) eventNames
  let filteredListener event@PropertyEvent { ev_atom = atom } =
        when (atom `elem` eventAtoms) $ catchAny (listener event) (const $ return ())
      filteredListener _ = return ()
  subscribeToAll filteredListener

handleX11Event :: Event -> Taffy IO ()
handleX11Event event =
  asksContextVar listeners >>= mapM_ applyListener
  where applyListener :: (Unique, Listener) -> Taffy IO ()
        applyListener (_, listener) = taffyFork $ listener event