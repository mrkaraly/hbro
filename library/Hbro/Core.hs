{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
module Hbro.Core (
-- * Types
      CaseSensitivity(..)
    , Direction(..)
    , Wrap(..)
    , ZoomDirection(..)
-- * Getters
    , getCurrentURI
    , getFaviconURI
    , getFavicon
    , getLoadProgress
    , getPageTitle
    , getPageData
-- * Browsing
    , goHome
    , load
    , reload
    , reloadBypassCache
    , stopLoading
    , goBack
    , goForward
-- * Other
    , printPage
    , searchText
    , searchText_
    , spawnHbro
    , spawnHbro'
    , quit
    , saveWebPage
    , executeJSFile
    ) where

-- {{{ Imports
import           Graphics.UI.Gtk.WebKit.Extended

import           Hbro.Config                              as Config
import           Hbro.Dyre
import           Hbro.Error
import           Hbro.Gui.MainView
import           Hbro.Logger
import           Hbro.Prelude                             as H

import           Control.Concurrent.STM.MonadIO

import           Data.IOData

import           Graphics.UI.Gtk.Gdk.Pixbuf               (Pixbuf)
import           Graphics.UI.Gtk.General.General.Extended
import           Graphics.UI.Gtk.WebKit.WebDataSource
import           Graphics.UI.Gtk.WebKit.WebFrame

import           Network.URI.Extended

import           System.Process.Extended
-- }}}

-- {{{ Types
data CaseSensitivity = CaseSensitive | CaseInsensitive

instance ToBool CaseSensitivity where
    toBool CaseSensitive   = True
    toBool CaseInsensitive = False

data Direction = Forward | Backward

instance ToBool Direction where
    toBool Forward  = True
    toBool Backward = False

data Wrap = Wrap | NoWrap

instance ToBool Wrap where
    toBool Wrap   = True
    toBool NoWrap = False

data ZoomDirection = In | Out
-- }}}

-- {{{ Getters
getCurrentURI :: (MonadIO m, MonadReader r m, Has MainView r, MonadThrow m) => m URI
getCurrentURI = webViewGetUri =<< getWebView

getFaviconURI :: (MonadIO m, MonadReader r m, Has MainView r, MonadThrow m) => m URI
getFaviconURI = webViewGetIconUri =<< getWebView

getFavicon :: (MonadIO m, MonadReader r m, Has MainView r, MonadThrow m) => Int -> Int -> m Pixbuf
getFavicon w h = (\v -> webViewTryGetFaviconPixbuf v w h) =<< getWebView

getLoadProgress :: (MonadIO m, MonadReader r m, Has MainView r) => m Double
getLoadProgress = gSync . webViewGetProgress =<< getWebView

getPageTitle :: (MonadIO m, MonadReader r m, Has MainView r, MonadThrow m) => m Text
getPageTitle = webViewGetTitle =<< getWebView

-- | Return the HTML code of the current webpage.
getPageData :: (MonadIO m, MonadReader r m, Has MainView r, MonadThrow m) => m ByteString
getPageData = dataSourceGetData =<< io . webFrameGetDataSource =<< io . webViewGetMainFrame =<< getWebView
-- }}}

-- {{{ Browsing
goHome :: (MonadIO m, MonadLogger m, MonadReader r m, Has MainView r, Has (TVar Config) r, MonadThrow m) => m ()
goHome = load =<< Config.get homePage_

load :: (MonadIO m, MonadLogger m, MonadReader r m, Has MainView r, MonadThrow m) => URI -> m ()
load uri = do
    debug $ "Loading URI: " <> show uri
    -- void . logErrors $ do
    --     currentURI <- getURI
    --     guard (currentURI /= uri')
    --     Browser.advance currentURI

    -- load' uri'
    webview <- getWebView
    gSync . webViewLoadUri webview $ (show uri' :: Text)

  where
    uri' = case uriScheme uri of
             [] -> uri { uriScheme = "http://" }
             _  -> uri
    -- baseOf uri = uri {
        -- uriPath = (++ "/") . join "/" . Prelude.init . split "/" $ uriPath uri
    -- }


-- load' :: (MonadBaseControl IO m, MonadReader GUI m, HasHTTPClient t, MonadThrow m) => URI -> m ()
-- load' uri = do
--     page <- Client.retrieve uri
--     -- render page =<< Client.getURI
--     render page uri


reload, goBack, goForward :: (MonadIO m, MonadReader r m, Has MainView r, MonadLogger m) => m ()
-- reload    = load  =<< Client.getURI
-- goBack    = load' =<< Browser.stepBackward =<< getURI
-- goForward = load' =<< Browser.stepForward =<< getURI
reload    = gAsync . webViewReload    =<< getWebView
goBack = do
  (gSync . webViewCanGoBack =<< getWebView) >>= (`unless` warning "Unable to go back.")
  gAsync . webViewGoBack    =<< getWebView
goForward = do
  (gSync . webViewCanGoForward =<< getWebView) >>= (`unless` warning "Unable to go forward.")
  gAsync . webViewGoForward =<< getWebView

reloadBypassCache, stopLoading :: (MonadIO m, MonadLogger m, MonadReader r m, Has MainView r) => m ()
reloadBypassCache = getWebView >>= gAsync . webViewReloadBypassCache >> debug "Reloading without cache."
stopLoading = getWebView >>= gAsync . webViewStopLoading >> debug "Stopped loading"
-- }}}


-- {{{
searchText :: (MonadIO m, MonadLogger m, MonadReader r m, Has MainView r) => CaseSensitivity -> Direction -> Wrap -> Text -> m Bool
searchText s d w text = do
    debug $ "Searching text: " <> text
    v <- getWebView
    gSync $ webViewSearchText v text (toBool s) (toBool d) (toBool w)

searchText_ :: (MonadIO m, MonadLogger m, MonadReader r m, Has MainView r) => CaseSensitivity -> Direction -> Wrap -> Text -> m ()
searchText_ s d w text = void $ searchText s d w text

printPage :: (MonadIO m, MonadReader r m, Has MainView r) => m ()
printPage = gAsync . webFramePrint =<< gSync . webViewGetMainFrame =<< getWebView
-- }}}

-- | Spawn another browser instance.
spawnHbro :: (MonadIO m, MonadLogger m) => m ()
spawnHbro = do
  executable <- getHbroExecutable
  spawn (pack executable) []

-- | Spawn another browser instance and load the given URI at start-up.
spawnHbro' :: (MonadIO m, MonadLogger m) => URI -> m ()
spawnHbro' uri = do
  executable <- getHbroExecutable
  spawn (pack executable) ["-u", show uri]

-- | Terminate the program.
quit :: (MonadIO m) => m ()
quit = gAsync mainQuit


-- {{{ Misc
saveWebPage :: (ControlIO m, MonadLogger m, MonadReader r m, Has MainView r, MonadThrow m) => FilePath -> m ()
saveWebPage file = writeFile file =<< getPageData

-- | Execute a javascript file on current webpage.
executeJSFile :: (MonadIO m, MonadLogger m) => FilePath -> WebView -> m ()
executeJSFile filePath webView' = do
    debug $ "Executing Javascript file: " <> pack filePath
    script <- readFile filePath
    let script' = unwords . map (<> "\n") . lines $ script

    gAsync $ webViewExecuteScript webView' (script' :: Text)
-- }}}

-- | Save current web page to a file,
-- along with all its resources in a separated directory.
-- Doesn't work for now, because web_resource_get_data's binding is missing...
_savePage :: Text -> WebView -> IO ()
_savePage _path webView' = do
    frame         <- webViewGetMainFrame webView'
    dataSource    <- webFrameGetDataSource frame
    _mainResource <- webDataSourceGetMainResource dataSource
    _subResources <- webDataSourceGetSubresources dataSource
    return ()
