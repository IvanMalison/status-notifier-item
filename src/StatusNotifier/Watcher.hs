{-# LANGUAGE OverloadedStrings #-}
module StatusNotifier.Watcher where

import Control.Monad
import Control.Concurrent.MVar
import DBus
import DBus.Client
import DBus.Internal.Message
import DBus.Internal.Types
import Data.Maybe
import Data.Coerce
import Data.Int
import Data.List
import Data.String
import StatusNotifier.Util
import Text.Printf

statusNotifierWatcherString :: String
statusNotifierWatcherString = "StatusNotifierWatcher"

nameOwnerChangedMatchRule =
  matchAny
  { matchSender = Just "org.freedesktop"
  , matchMember = Just "NameOwnerChanged"
  }

data ItemEntry = ItemEntry
  { serviceName :: String }

data WatcherParams = WatcherParams
  { watcherNamespace :: String
  , watcherPath :: String
  , watcherLogger :: String -> IO ()
  , watcherStop :: IO ()
  , watcherClient :: Maybe Client
  }

defaultWatcherParams =
  WatcherParams
  { watcherNamespace = "org.freedesktop"
  , watcherLogger = putStrLn
  , watcherStop = return ()
  , watcherPath = "/StatusNotifierWatcher"
  , watcherClient = Nothing
  }

startWatcher WatcherParams
               { watcherNamespace = interfaceNamespace
               , watcherLogger = log
               , watcherStop = stopWatcher
               , watcherPath = path
               , watcherClient = mclient
               } = do
  let watcherInterfaceName =
        fromString $ printf "%s.%s" interfaceNamespace statusNotifierWatcherString

  client <- maybe connectSession return mclient
  nameRequestResult <- requestName client (coerce watcherInterfaceName) []

  notifierItems <- newMVar []
  notifierHosts <- newMVar []

  let watcherSignal =
        Signal
        { signalPath = fromString path
        , signalInterface = watcherInterfaceName
        , signalMember = ""
        , signalSender = Nothing
        , signalDestination = Nothing
        , signalBody = []
        }

      emitFromWatcher signal name = do
        log $ printf "Emitting %s with: [%s]" (show signal) name
        emit client
             watcherSignal { signalMember = signal
                           , signalBody = [toVariant name]
                           }

      nameIsRegistered name items =
        isJust $ find ((== name) . serviceName) items

      registerStatusNotifierItem name =
        modifyMVar_ notifierItems $ \currentItems ->
          if nameIsRegistered name currentItems
          then
            return currentItems
          else
            do
              emitFromWatcher "StatusNotifierItemRegistered" name
              return $ ItemEntry { serviceName = name } : currentItems

      registerStatusNotifierHost name =
        modifyMVar_ notifierHosts $ \currentHosts ->
          if nameIsRegistered name currentHosts
          then
            return currentHosts
          else
            do
              emit client watcherSignal { signalMember = "StatusNotifierHostRegistered" }
              return $ ItemEntry { serviceName = name } : currentHosts

      registeredStatusNotifierItems = map serviceName <$> readMVar notifierItems

      isStatusNotifierHostRegistered = not . null <$> readMVar notifierHosts

      protocolVersion = return 1 :: IO Int32

      filterDeadService deadService mvar =
        modifyMVar mvar $ return . partition ((/= deadService) . serviceName)

      handleNameOwnerChanged signal =
        case map fromVariant $ signalBody signal of
          [(Just name), (Just oldOwner), (Just newOwner)] ->
            when (newOwner == "") $
                 do
                   removedItems <- filterDeadService name notifierItems
                   when (not $ null removedItems) $
                        emitFromWatcher "StatusNotifierItemUnregistered" name
                   removedHosts <- filterDeadService name notifierHosts
                   return ()
          _ -> return ()

      watcherMethods =
        [ autoMethod "RegisterStatusNotifierItem" registerStatusNotifierItem
        , autoMethod "RegisterStatusNotifierHost" registerStatusNotifierHost
        , autoMethod "stopWatcher" stopWatcher
        ]

      watcherProperties =
        [ readOnlyProperty "RegisteredStatusNotifierItems" registeredStatusNotifierItems
        , readOnlyProperty "IsStatusNotifierHostRegistered" isStatusNotifierHostRegistered
        , readOnlyProperty "ProtocolVersion" protocolVersion
        ]

      watcherInterface =
        Interface
        { interfaceName = watcherInterfaceName
        , interfaceMethods = watcherMethods
        , interfaceProperties = watcherProperties
        , interfaceSignals = []
        }

  case nameRequestResult of
    NamePrimaryOwner ->
      do
        _ <- addMatch client nameOwnerChangedMatchRule handleNameOwnerChanged
        export client (fromString path) watcherInterface
    _ -> stopWatcher

  return nameRequestResult