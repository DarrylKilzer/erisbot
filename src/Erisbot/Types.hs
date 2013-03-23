{-# LANGUAGE FlexibleContexts, TemplateHaskell, OverloadedStrings, 
             ConstraintKinds, ScopedTypeVariables, ImpredicativeTypes #-}
module Erisbot.Types where

import Network.IRC.ByteString.Parser
import Network (PortNumber)

import Control.Lens
import Data.ByteString.Char8 as BS
import Data.HashMap.Strict as HashMap

import Control.Monad.IO.Class
import Control.Monad.State.Strict
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Applicative
import Control.Exception.Lifted
import Data.Monoid
import Data.Maybe
import Data.String

import Control.Concurrent.Lifted
import System.Mem.Weak
import System.Plugins.Load (Module)
import System.IO


type PluginName = String

data BotConf = 
  BotConf { network :: String
          , port :: PortNumber
          , nick :: String
          , user :: String
          , realname :: String
          , cmdPrefixes :: String
          , channels :: [String]
          , dataDir :: FilePath
          , pluginDir :: FilePath
          , pluginIncludeDirs :: [FilePath]
          , plugins :: [(PluginName, FilePath)]
          }

defaultBotConf = BotConf { network = confErr "network address"
                         , port = confErr "port number"
                         , nick = confErr "nick name"
                         , user = confErr "user name"
                         , realname = confErr "real name"
                         , cmdPrefixes = "!"
                         , channels = []
                         , dataDir = confErr "data directory"
                         , pluginDir = confErr "plugin directory"
                         , pluginIncludeDirs = []
                         , plugins = []
                         }
  where
    confErr field = error $ "No " ++ field ++ " specified in bot configuration"


data CommandData = CommandData { _cmdChannel   :: ByteString
                               , _cmdUserInfo  :: UserInfo
                               , _cmdParams    :: ByteString
                               , _cmdParamList :: [ByteString]
                               }
                   
data BotState s = 
  BotState { _botConf :: MVar BotConf
           , _outQueue :: Chan IRCMsg
           , _inQueue  :: Chan IRCMsg
           , _chanLocks :: MVar (HashMap ByteString (MVar ThreadId))
           , _cmdHandlers :: MVar (HashMap ByteString 
                                   (forall s'. CommandHandler s' ()))
           , _pluginMap :: MVar (HashMap PluginName (PluginState))
           , _currentChanLock :: Maybe (MVar ThreadId)
           , _currentPlugin :: Maybe Plugin
           , _debugMode :: Bool
           , _debugLock :: MVar ThreadId
           , _localState :: s
           }

data Plugin = Plugin { onLoad :: Bot () ()
                     , onUnload :: Bot () ()
                     }
               
defaultPlugin = Plugin (return ()) (return ())

data PluginState =
  PluginState { pluginData     :: Plugin
              , pluginModule   :: Module
              , pluginThreads  :: [Weak ThreadId] 
              }


-- |convenient typeclass synonym
type BotMonad s bot = ( MonadIO (bot s), MonadState (BotState s) (bot s)
                      , Functor (bot s), MonadBaseControl IO (bot s))

-- |base bot monad
type Bot s = StateT (BotState s) IO

-- |monad transformer used with 'withChannel'
type ChannelWriterT = ReaderT ByteString


type InputListener s = IRCMsg -> Bot s ()

-- |monad trasnformer for command handlers
type CommandHandler s = ReaderT CommandData (Bot s)

makeLenses ''CommandData
makeLenses ''BotState


newBotState :: MonadIO io => BotConf -> s -> io (BotState s)
newBotState conf s = liftIO $ do
  confVar <- newMVar conf
  outQ <- newChan
  inQ <- newChan
  chanL <- newMVar HashMap.empty
  cmdH <- newMVar HashMap.empty
  plugs <- newMVar HashMap.empty
  debugL <- newEmptyMVar
  return $ BotState confVar outQ inQ chanL cmdH plugs Nothing Nothing 
                    False debugL s

copyBotState :: BotMonad s bot => s' -> bot s (BotState s')
copyBotState s' = do
  confVar <- use botConf
  inQ' <- dupChan =<< use inQueue 
  outQ' <- dupChan =<< use outQueue
  chanL' <- use chanLocks
  cmdH' <- use cmdHandlers
  plugs <- use pluginMap
  currentPlug <- use currentPlugin
  debugMode' <- use debugMode
  debugL' <- use debugLock
  return $ BotState confVar outQ' inQ' chanL' cmdH' plugs Nothing currentPlug 
                    debugMode' debugL' s'

runBot :: BotState s -> Bot s a -> IO a
runBot = flip evalStateT
  
forkBot :: BotMonad s bot => 
           s' -> Bot s' () -> bot s ThreadId
forkBot s' botAct = do
  botState' <- copyBotState s'
  --forkFinally (set botState' >> bot) finalizer
  liftIO . fork . runBot botState' $ botAct >> finalizer undefined
  where
    finalizer _ = do
      maybe (return ()) (void . liftIO . tryTakeMVar) =<< use currentChanLock
      
  
forkBot_ :: BotMonad s bot => s' -> Bot s' () -> bot s ()
forkBot_ s' = void . forkBot s'
  

runInputListener :: InputListener s -> Bot s a
runInputListener listener = 
  forever {-. handle exHandler -} $ listener =<< recvMsg
  where
    exHandler (e :: SomeException) = debugMsg (show e)

forkInputListener :: s' -> InputListener s' -> Bot s ThreadId
forkInputListener s' = forkBot s' . runInputListener

forkInputListener_ :: s' -> InputListener s' -> Bot s ()
forkInputListener_ s' = void . forkInputListener s'

runCommandHandler :: CommandData -> CommandHandler s a -> Bot s a
runCommandHandler = flip runReaderT


sendMsg :: BotMonad s bot => 
           ByteString -> [ByteString] -> ByteString -> bot s ()
sendMsg cmd params trail = do
  outQ <- use outQueue
  let msg = ircMsg cmd params trail
  debugMsg $ "Sending message to output queue: " 
    <> fromString (show msg)
  liftIO . writeChan outQ $ ircMsg cmd params trail

recvMsg :: BotMonad s bot => bot s IRCMsg
recvMsg = liftIO . readChan =<< use inQueue

say :: BotMonad s bot => ByteString -> ChannelWriterT (bot s) ()
say chanMsg = do 
  channel <- ask
  sendMsg "PRIVMSG" [channel] chanMsg

emote :: BotMonad s bot => ByteString -> ChannelWriterT (bot s) ()
emote chanMsg = do
  channel <- ask
  sendMsg "PRIVMSG" [channel] $ "\x01\&ACTION " <> chanMsg <> "\x01"


lockChannel :: BotMonad s bot => ByteString -> bot s ()
lockChannel channel = do
  isLocking <- isJust <$> use currentChanLock
  when isLocking $ error "Thread is already locking a channel"
    
  lockMapVar <- use chanLocks
  lockMap <- liftIO $ takeMVar lockMapVar
  let mChanLock = HashMap.lookup channel lockMap
  chanLock <- 
    liftIO $ case mChanLock of
      Just lock -> do
        putMVar lockMapVar lockMap
        return lock   
      Nothing -> do  
        lock <- newEmptyMVar
        putMVar lockMapVar (HashMap.insert channel lock lockMap)
        return lock
  liftIO $ putMVar chanLock =<< myThreadId
  currentChanLock .= Just chanLock

unlockChannel :: BotMonad s bot => bot s ()
unlockChannel = do 
  mLock <- use currentChanLock
  case mLock of
    Just lock -> do
      liftIO . void . tryTakeMVar $ lock
      currentChanLock .= Nothing
    Nothing ->
      return ()

withChannel :: BotMonad s bot => 
               ByteString -> ChannelWriterT (bot s) a -> bot s a
withChannel channel cWriter = do
  lockChannel channel
  result <- runReaderT cWriter channel `finally` unlockChannel
  currentChanLock .= Nothing -- needed because finally discards state changes
  return result

replyToChannel :: ChannelWriterT (CommandHandler s) a -> CommandHandler s a
replyToChannel writer = do
  channel <- view cmdChannel
  withChannel channel writer


debugMsg :: BotMonad s bot => String -> bot s ()
debugMsg msg = do
  isDebugMode <- use debugMode
  when isDebugMode $ do
    lock <- use debugLock
    liftIO $ do
      threadId <- myThreadId
      let outputThread = do
            putMVar lock threadId
            System.IO.hPutStrLn stderr $ show threadId <> ": " <> msg
          finalizer _ = void . liftIO $ takeMVar lock
      --forkFinally outputThread finalizer
      void $ fork ( outputThread >> finalizer undefined)
  
debugMsgByteString :: BotMonad s bot => ByteString -> bot s ()
debugMsgByteString = debugMsg . BS.unpack

isCmdPrefix :: Char -> Bot s Bool
isCmdPrefix c = use botConf 
                >>= readMVar
                >>= return . (c `Prelude.elem`) . cmdPrefixes