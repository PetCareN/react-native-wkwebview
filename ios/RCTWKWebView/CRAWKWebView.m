#import "CRAWKWebView.h"

#import "WeakScriptMessageDelegate.h"

#import <UIKit/UIKit.h>

#import <React/RCTAutoInsetsProtocol.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/RCTView.h>
#import <React/UIView+React.h>

#import <objc/runtime.h>

// runtime trick to remove WKWebView keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelperWKB : NSObject @end
@implementation _SwizzleHelperWKB
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface CRAWKWebView () <WKNavigationDelegate, RCTAutoInsetsProtocol, WKScriptMessageHandler, WKUIDelegate, UIScrollViewDelegate>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onProgress;
@property (nonatomic, copy) RCTDirectEventBlock onMessage;
@property (nonatomic, copy) RCTDirectEventBlock onScroll;
@property (nonatomic, copy) RCTDirectEventBlock onNavigationResponse;
@property (assign) BOOL sendCookies;
@property (nonatomic, strong) WKUserScript *atStartScript;
@property (nonatomic, strong) WKUserScript *atEndScript;

@end

@implementation CRAWKWebView
{
  WKWebView *_webView;
  BOOL _injectJavaScriptForMainFrameOnly;
  BOOL _injectedJavaScriptForMainFrameOnly;
  NSString *_injectJavaScript;
  NSString *_injectedJavaScript;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  return self = [super initWithFrame:frame];
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (instancetype)initWithProcessPool:(WKProcessPool *)processPool
{
  if(self = [self initWithFrame:CGRectZero])
  {
    super.backgroundColor = [UIColor clearColor];
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
    _keyboardHeight = 0;
    _keyboardShowing = false;

    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
    config.processPool = processPool;
    WKUserContentController* userController = [[WKUserContentController alloc]init];
    [userController addScriptMessageHandler:[[WeakScriptMessageDelegate alloc] initWithDelegate:self] name:@"reactNative"];
    config.userContentController = userController;

    _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration:config];
    _webView.UIDelegate = self;
    _webView.navigationDelegate = self;
    _webView.scrollView.delegate = self;

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
    // `contentInsetAdjustmentBehavior` is only available since iOS 11.
    // We set the default behavior to "never" so that iOS
    // doesn't do weird things to UIScrollView insets automatically
    // and keeps it as an opt-in behavior.
    if ([_webView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
      _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
#endif
    [self setupPostMessageScript];
    [_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    [self addSubview:_webView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
  }
  return self;
}

- (void)setInjectJavaScript:(NSString *)injectJavaScript {
  _injectJavaScript = injectJavaScript;
  self.atStartScript = [[WKUserScript alloc] initWithSource:injectJavaScript
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:_injectJavaScriptForMainFrameOnly];
  [self resetupScripts];
}

- (void)setInjectedJavaScript:(NSString *)script {
  _injectedJavaScript = script;
  self.atEndScript = [[WKUserScript alloc] initWithSource:script
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                         forMainFrameOnly:_injectedJavaScriptForMainFrameOnly];
  [self resetupScripts];
}

- (void)setInjectedJavaScriptForMainFrameOnly:(BOOL)injectedJavaScriptForMainFrameOnly {
  _injectedJavaScriptForMainFrameOnly = injectedJavaScriptForMainFrameOnly;
  if (_injectedJavaScript != nil) {
    [self setInjectedJavaScript:_injectedJavaScript];
  }
}

- (void)setInjectJavaScriptForMainFrameOnly:(BOOL)injectJavaScriptForMainFrameOnly {
  _injectJavaScriptForMainFrameOnly = injectJavaScriptForMainFrameOnly;
  if (_injectJavaScript != nil) {
    [self setInjectJavaScript:_injectJavaScript];
  }
}

- (void)setMessagingEnabled:(BOOL)messagingEnabled {
  _messagingEnabled = messagingEnabled;
  [self setupPostMessageScript];
}

- (void)resetupScripts {
  [_webView.configuration.userContentController removeAllUserScripts];
  [self setupPostMessageScript];
  if (self.atStartScript) {
    [_webView.configuration.userContentController addUserScript:self.atStartScript];
  }
  if (self.atEndScript) {
    [_webView.configuration.userContentController addUserScript:self.atEndScript];
  }
}

- (void)setupPostMessageScript {
  if (_messagingEnabled) {
    NSString *source = @"window.originalPostMessage = window.postMessage;"
    "window.postMessage = function(message, targetOrigin, transfer) {"
      "window.webkit.messageHandlers.reactNative.postMessage(message);"
      "if (typeof targetOrigin !== 'undefined') {"
        "window.originalPostMessage(message, targetOrigin, transfer);"
      "}"
    "};";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:source
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:_injectedJavaScriptForMainFrameOnly];
    [_webView.configuration.userContentController addUserScript:script];
  }
}

- (void)loadRequest:(NSURLRequest *)request
{
  if (request.URL && _sendCookies) {
    NSDictionary *cookies = [NSHTTPCookie requestHeaderFieldsWithCookies:[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:request.URL]];
    if ([cookies objectForKey:@"Cookie"]) {
      NSMutableURLRequest *mutableRequest = request.mutableCopy;
      [mutableRequest addValue:cookies[@"Cookie"] forHTTPHeaderField:@"Cookie"];
      request = mutableRequest;
    }
  }

  [_webView loadRequest:request];
}

-(void)setAllowsLinkPreview:(BOOL)allowsLinkPreview
{
  if ([_webView respondsToSelector:@selector(allowsLinkPreview)]) {
    _webView.allowsLinkPreview = allowsLinkPreview;
  }
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (!hideKeyboardAccessoryView) {
    return;
  }

  UIView* subview;
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"WKContent"])
      subview = view;
  }

  if(subview == nil) return;

  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelperWKB", subview.class.superclass];
  Class newClass = NSClassFromString(name);

  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;

    Method method = class_getInstanceMethod([_SwizzleHelperWKB class], @selector(inputAccessoryView));
    class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

    objc_registerClassPair(newClass);
  }

  object_setClass(subview, newClass);
}

// https://github.com/Telerik-Verified-Plugins/WKWebView/commit/04e8296adeb61f289f9c698045c19b62d080c7e3
// https://stackoverflow.com/a/48623286/3297914
-(void)setKeyboardDisplayRequiresUserAction:(BOOL)keyboardDisplayRequiresUserAction
{
  if (!keyboardDisplayRequiresUserAction) {
    Class class = NSClassFromString(@"WKContentView");
    NSOperatingSystemVersion iOS_11_3_0 = (NSOperatingSystemVersion){11, 3, 0};

    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: iOS_11_3_0]) {
      SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:changingActivityState:userObject:");
      Method method = class_getInstanceMethod(class, selector);
      IMP original = method_getImplementation(method);
      IMP override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, BOOL arg3, id arg4) {
        ((void (*)(id, SEL, void*, BOOL, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3, arg4);
      });
      method_setImplementation(method, override);
    } else {
      SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:userObject:");
      Method method = class_getInstanceMethod(class, selector);
      IMP original = method_getImplementation(method);
      IMP override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, id arg3) {
        ((void (*)(id, SEL, void*, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3);
      });
      method_setImplementation(method, override);
    }
  }
}

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
- (void)setContentInsetAdjustmentBehavior:(UIScrollViewContentInsetAdjustmentBehavior)behavior
{
  // `contentInsetAdjustmentBehavior` is available since iOS 11.
  if ([_webView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
    CGPoint contentOffset = _webView.scrollView.contentOffset;
    _webView.scrollView.contentInsetAdjustmentBehavior = behavior;
    _webView.scrollView.contentOffset = contentOffset;
  }
}
#endif

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
  if (_onMessage) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
                                       @"data": message.body,
                                       @"name": message.name
                                       }];
    _onMessage(event);
  }
}

- (void)goForward
{
  [_webView goForward];
}

- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^)(id, NSError *error))completionHandler
{
  [_webView evaluateJavaScript:javaScriptString completionHandler:completionHandler];
}

- (void)postMessage:(NSString *)message
{
  NSDictionary *eventInitDict = @{
                                  @"data": message,
                                  };
  NSString *source = [NSString
                      stringWithFormat:@"document.dispatchEvent(new MessageEvent('message', %@));",
                      RCTJSONStringify(eventInitDict, NULL)
                      ];
  [_webView evaluateJavaScript:source completionHandler:nil];
}


- (void)goBack
{
  [_webView goBack];
}

- (BOOL)canGoBack
{
  return [_webView canGoBack];
}

- (BOOL)canGoForward
{
  return [_webView canGoForward];
}

- (void)reload
{
  [_webView reload];
}

- (void)stopLoading
{
  [_webView stopLoading];
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];
    _sendCookies = [source[@"sendCookies"] boolValue];
    if ([source[@"customUserAgent"] length] != 0 && [_webView respondsToSelector:@selector(setCustomUserAgent:)]) {
      [_webView setCustomUserAgent:source[@"customUserAgent"]];
    }

    // Allow loading local files:
    // <WKWebView source={{ file: RNFS.MainBundlePath + '/data/index.html', allowingReadAccessToURL: RNFS.MainBundlePath }} />
    // Only works for iOS 9+. So iOS 8 will simply ignore those two values
    NSString *file = [RCTConvert NSString:source[@"file"]];
    NSString *allowingReadAccessToURL = [RCTConvert NSString:source[@"allowingReadAccessToURL"]];

    if (file && [_webView respondsToSelector:@selector(loadFileURL:allowingReadAccessToURL:)]) {
      NSURL *fileURL = [RCTConvert NSURL:file];
      NSURL *baseURL = [RCTConvert NSURL:allowingReadAccessToURL];
      [_webView loadFileURL:fileURL allowingReadAccessToURL:baseURL];
      return;
    }

    // Check for a static html source first
    NSString *html = [RCTConvert NSString:source[@"html"]];
    if (html) {
      NSURL *baseURL = [RCTConvert NSURL:source[@"baseUrl"]];
      if (!baseURL) {
        baseURL = [NSURL URLWithString:@"about:blank"];
      }
      [_webView loadHTMLString:html baseURL:baseURL];
      return;
    }

    NSURLRequest *request = [RCTConvert NSURLRequest:source];
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page. bc
    if ([request.URL isEqual:_webView.URL]) {
      return;
    }
    if (!request.URL) {
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
    [self loadRequest:request];
  }
}

// TODO RT: hacks begin here

- (void)keyboardWillShow:(NSNotification *)notification
{
  _keyboardHeight = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
  _keyboardShowing = true;
  _keyboardWillShow = true;
  [self setNeedsLayout];
}

- (void)keyboardDidShow:(NSNotification *)notification
{
  _keyboardHeight = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
  _keyboardShowing = true;
  _keyboardWillShow = false;
  [self setNeedsLayout];
}

- (void)keyboardWillHide:(NSNotification *)notification
{
  _keyboardShowing = false;
  _keyboardWillShow = false;
  [self setNeedsLayout];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  if (!_webView.scrollView.scrollEnabled) {
    scrollView.contentOffset = CGPointMake(0,0);
  }

  NSDictionary *event = @{
                          @"contentOffset": @{
                              @"x": @(scrollView.contentOffset.x),
                              @"y": @(scrollView.contentOffset.y)
                              },
                          @"contentInset": @{
                              @"top": @(scrollView.contentInset.top),
                              @"left": @(scrollView.contentInset.left),
                              @"bottom": @(scrollView.contentInset.bottom),
                              @"right": @(scrollView.contentInset.right)
                              },
                          @"contentSize": @{
                              @"width": @(scrollView.contentSize.width),
                              @"height": @(scrollView.contentSize.height)
                              },
                          @"layoutMeasurement": @{
                              @"width": @(scrollView.frame.size.width),
                              @"height": @(scrollView.frame.size.height)
                              },
                          @"zoomScale": @(scrollView.zoomScale ?: 1),
                          };

  _onScroll(event);
}

- (void)logSituation:(NSString *)context {
  /*CGSize size = _webView.scrollView.contentSize;
  RCTLogInfo(@"------------------------------------------------------------------------------");
  RCTLogInfo(@"[%@] keyboard height %f", context, _keyboardHeight);
  RCTLogInfo(@"[%@] content size %f, %f", context, size.width, size.height);
  RCTLogInfo(@"[%@] scroll insets %f, %f", context, _webView.scrollView.contentInset.top, _webView.scrollView.contentInset.bottom);
  RCTLogInfo(@"[%@] scroll content offset %f", context, _webView.scrollView.contentOffset.y);
  RCTLogInfo(@"[%@] container frame %f top %f bottom", context, _webView.frame.origin.y, _webView.frame.size.height);
  RCTLogInfo(@"[%@] container bounds %f top %f bottom", context, _webView.bounds.origin.y, _webView.bounds.size.height);*/
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (_webView.scrollView.scrollEnabled || !_keyboardShowing) {
    _webView.frame = self.bounds;
  } else {
    CGRect frame = CGRectMake(self.bounds.origin.x, self.bounds.origin.y, self.bounds.size.width, self.bounds.size.height - _keyboardHeight);
    _webView.frame = frame;
    //[self logSituation:@"setCustomLayout"];
  }
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = _webView.scrollView.opaque = (alpha == 1.0);
  _webView.backgroundColor = _webView.scrollView.backgroundColor = backgroundColor;
}

- (UIColor *)backgroundColor
{
  return _webView.backgroundColor;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
                                                                                                 @"url": _webView.URL.absoluteString ?: @"",
                                                                                                 @"loading" : @(_webView.loading),
                                                                                                 @"title": _webView.title,
                                                                                                 @"canGoBack": @(_webView.canGoBack),
                                                                                                 @"canGoForward" : @(_webView.canGoForward),
                                                                                                 }];

  return event;
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"estimatedProgress"]) {
    if (!_onProgress) {
      return;
    }
    _onProgress(@{@"progress": [change objectForKey:NSKeyValueChangeNewKey]});
  }
}

- (void)dealloc
{
  [_webView removeObserver:self forKeyPath:@"estimatedProgress"];
  _webView.navigationDelegate = nil;
  _webView.UIDelegate = nil;
  _webView.scrollView.delegate = nil;
}

#pragma mark - WKNavigationDelegate methods

#if DEBUG
- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
  NSURLCredential * credential = [[NSURLCredential alloc] initWithTrust:[challenge protectionSpace].serverTrust];
  completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
}
#endif

- (void)webView:(__unused WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  UIApplication *app = [UIApplication sharedApplication];
  NSURLRequest *request = navigationAction.request;
  NSURL* url = request.URL;
  NSString* scheme = url.scheme;

  BOOL isJSNavigation = [scheme isEqualToString:RCTJSNavigationScheme];

  // handle mailto and tel schemes
  if ([scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"tel"]) {
    if ([app canOpenURL:url]) {
      [app openURL:url];
      decisionHandler(WKNavigationActionPolicyCancel);
      return;
    }
  }

  // skip this for the JS Navigation handler
  if (!isJSNavigation && _onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
                                       @"url": (request.URL).absoluteString,
                                       @"navigationType": @(navigationAction.navigationType)
                                       }];
    if (![self.delegate webView:self
      shouldStartLoadForRequest:event
                   withCallback:_onShouldStartLoadWithRequest]) {
      return decisionHandler(WKNavigationActionPolicyCancel);
    }
  }

  if (_onLoadingStart) {
    // We have this check to filter out iframe requests and whatnot
    BOOL isTopFrame = [url isEqual:request.mainDocumentURL];
    if (isTopFrame) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary: @{
                                         @"url": url.absoluteString,
                                         @"navigationType": @(navigationAction.navigationType)
                                         }];
      _onLoadingStart(event);
    }
  }

  if (isJSNavigation) {
    decisionHandler(WKNavigationActionPolicyCancel);
  }
  else {
    decisionHandler(WKNavigationActionPolicyAllow);
  }
}

- (void)webView:(__unused WKWebView *)webView didFailProvisionalNavigation:(__unused WKNavigation *)navigation withError:(NSError *)error
{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
                                      @"domain": error.domain,
                                      @"code": @(error.code),
                                      @"description": error.localizedDescription,
                                      }];
    _onLoadingError(event);
  }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(__unused WKNavigation *)navigation
{
  if (_messagingEnabled) {
#if RCT_DEV
    // See isNative in lodash
    NSString *testPostMessageNative = @"String(window.postMessage) === String(Object.hasOwnProperty).replace('hasOwnProperty', 'postMessage')";

    [webView evaluateJavaScript:testPostMessageNative completionHandler:^(id result, NSError *error) {
      if (!result) {
        RCTLogWarn(@"Setting onMessage on a WebView overrides existing values of window.postMessage, but a previous value was defined");
      }
    }];
#endif
    NSString *source = [NSString stringWithFormat:
                        @"window.originalPostMessage = window.postMessage;"
                        "window.postMessage = function() {"
                        "return window.webkit.messageHandlers.reactNative.postMessage.apply(window.webkit.messageHandlers.reactNative, arguments);"
                        "};"
                        ];

    [webView evaluateJavaScript:source completionHandler:nil];
  }
  if (_injectedJavaScript != nil) {
    [webView evaluateJavaScript:_injectedJavaScript completionHandler:^(id result, NSError *error) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      event[@"jsEvaluationValue"] = [NSString stringWithFormat:@"%@", result];
      _onLoadingFinish(event);
    }];
  }
  // we only need the final 'finishLoad' call so only fire the event when we're actually done loading.
  if (_onLoadingFinish && !webView.loading && ![webView.URL.absoluteString isEqualToString:@"about:blank"]) {
    _onLoadingFinish([self baseEvent]);
  }
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];

  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Close", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler();
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {

  // TODO We have to think message to confirm "YES"
  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    completionHandler(YES);
  }]];
  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(NO);
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {

  UIAlertController *alertController = [UIAlertController alertControllerWithTitle:prompt message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.text = defaultText;
  }];

  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    NSString *input = ((UITextField *)alertController.textFields.firstObject).text;
    completionHandler(input);
  }]];

  [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(nil);
  }]];
  UIViewController *presentingController = RCTPresentedViewController();
  [presentingController presentViewController:alertController animated:YES completion:nil];
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
  NSString *scheme = navigationAction.request.URL.scheme;
  if ((navigationAction.targetFrame.isMainFrame || _openNewWindowInWebView) && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
    [webView loadRequest:navigationAction.request];
  } else {
    UIApplication *app = [UIApplication sharedApplication];
    NSURL *url = navigationAction.request.URL;
    if ([app canOpenURL:url]) {
      [app openURL:url];
    }
  }
  return nil;
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
  RCTLogWarn(@"Webview Process Terminated");
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  if (_onNavigationResponse) {
    NSDictionary *headers = @{};
    NSInteger statusCode = 200;
    if([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]){
        headers = ((NSHTTPURLResponse *)navigationResponse.response).allHeaderFields;
        statusCode = ((NSHTTPURLResponse *)navigationResponse.response).statusCode;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
                                      @"headers": headers,
                                      @"status": [NSHTTPURLResponse localizedStringForStatusCode:statusCode],
                                      @"statusCode": @(statusCode),
                                      }];
    _onNavigationResponse(event);
  }

  decisionHandler(WKNavigationResponsePolicyAllow);
}
@end
