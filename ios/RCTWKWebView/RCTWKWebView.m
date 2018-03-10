#import "RCTWKWebView.h"

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
@interface _SwizzleHelperWK : NSObject @end
@implementation _SwizzleHelperWK
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface RCTWKWebView () <WKNavigationDelegate, RCTAutoInsetsProtocol, WKScriptMessageHandler, WKUIDelegate, UIScrollViewDelegate>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onProgress;
@property (nonatomic, copy) RCTDirectEventBlock onMessage;
@property (nonatomic, copy) RCTDirectEventBlock onScroll;
@property (assign) BOOL sendCookies;

@end

@implementation RCTWKWebView
{
  WKWebView *_webView;
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

    [_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:nil];
    [self addSubview:_webView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
  }
  return self;
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

  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelperWK", subview.class.superclass];
  Class newClass = NSClassFromString(name);

  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;

    Method method = class_getInstanceMethod([_SwizzleHelperWK class], @selector(inputAccessoryView));
    class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

    objc_registerClassPair(newClass);
  }

  object_setClass(subview, newClass);
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
    // the existing page.
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

/*- (void)viewDidLoad
{
  [super viewDidLoad];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
}*/

- (void)keyboardWillShow:(NSNotification *)notification
{
  _keyboardShowing = true;
  _keyboardWillShow = true;

  _oldScrollDelegate = _webView.scrollView.delegate;
  _oldOffset = _webView.scrollView.contentOffset;
  _webView.scrollView.delegate = self;

  //CGRect screenRect = [[UIScreen mainScreen] bounds];
  //CGRect frame = CGRectMake(0, 0, 375, 435);
  //CGRect frame = CGRectMake(_webView.bounds.origin.x, _webView.bounds.origin.y, screenRect.size.width, screenRect.size.height - _keyboardHeight);
  //_webView.frame = frame;
  //_webView.bounds = frame;
}

- (void)keyboardDidShow:(NSNotification *)notification
{
  _keyboardShowing = true;
  _keyboardWillShow = false;

  _webView.scrollView.delegate = _oldScrollDelegate;

  //CGRect screenRect = [[UIScreen mainScreen] bounds];
  //CGRect frame = CGRectMake(_webView.bounds.origin.x, _webView.bounds.origin.y, screenRect.size.width, screenRect.size.height - _keyboardHeight);
  //_webView.frame = frame;
  //_webView.bounds = frame;

  // https://medium.com/@dzungnguyen.hcm/autolayout-for-scrollview-keyboard-handling-in-ios-5a47d73fd023
  //_webView.constraintContentHeight.constant = screenRect.size.height - _keyboardHeight;
  //_webView.scrollView.constraintContentHeight.constant = screenRect.size.height - _keyboardHeight;

  //_webView.scrollView.contentSize=CGSizeMake(screenRect.size.width,screenRect.size.height - _keyboardHeight);
  //_webView.scrollView.contentInset=UIEdgeInsetsMake(0.0,0.0,0.0,0.0);
  //_webView.scrollView.scrollIndicatorInsets=UIEdgeInsetsMake(0.0,0.0,0.0,0.0);
  //RCTLog(@"content size %f x %f; inset bottom %f", _webView.scrollView.contentSize.width, _webView.scrollView.contentSize.height, _webView.scrollView.contentInset.bottom);

  //_webView.scrollView.scrollEnabled = false;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  //scrollView.contentOffset = _oldOffset;
}


- (void)keyboardWillHide:(NSNotification *)notification
{
  _keyboardShowing = false;
  _keyboardWillShow = false;
  //CGRect screenRect = [[UIScreen mainScreen] bounds];
  //CGRect frame = CGRectMake(0, 0, 375, 435);
  //CGRect frame = CGRectMake(_webView.bounds.origin.x, _webView.bounds.origin.y, screenRect.size.width, screenRect.size.height);
  //_webView.frame = frame;
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification
{
  _keyboardHeight = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  CGRect screenRect = [[UIScreen mainScreen] bounds];
  //CGRect frame = CGRectMake(0, 0, screenRect.size.width, screenRect.size.height - _keyboardHeight);

  // Setting the frame to a set value that wouldn't overlap with the keyboard
  // has all the desired behavior. Must be like.... when the keyboard shows,
  // and the WKWebView is big enough, it adds padding until the keyboard hides,
  // so changing the frame doesn't help?
  //CGRect frame = _keyboardShowing ? CGRectMake(0, 0, 375, 435) : CGRectMake(0, 0, screenRect.size.width, screenRect.size.height);
  //CGRect frame = CGRectMake(0, 0, 375, screenRect.size.height - _keyboardHeight - 135);
  CGRect frame = CGRectMake(_webView.bounds.origin.x, _webView.bounds.origin.y, screenRect.size.width, _keyboardShowing ? screenRect.size.height - _keyboardHeight : screenRect.size.height);

  // Logically we just want frame...
  _webView.frame = frame;
  //_webView.bounds = frame;
  // This is also a possible option, but I think not the right one.
  //_webView.scrollView.bounds = frame;
  //RCTLog(@"BOUNDS: x:%f, y:%f w:%f, h:%f", _webView.bounds.origin.x, _webView.bounds.origin.y, _webView.bounds.size.width, _webView.bounds.size.height);
  //RCTLog(@"FRAME: x:%f, y:%f w:%f, h:%f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
  //RCTLog(@"desired height: %f screen size - %f keyboard height = %f", screenRect.size.height, _keyboardHeight, screenRect.size.height - _keyboardHeight);

  /*
  _webView.scrollView.contentSize=CGSizeMake(320,758);
  _webView.scrollView.contentInset=UIEdgeInsetsMake(0.0,0.0,0.0,0.0);
  _webView.scrollView.scrollIndicatorInsets=UIEdgeInsetsMake(0.0,0.0,0.0,0.0);
  RCTLog(@"content size %f x %f; inset bottom %f", _webView.scrollView.contentSize.width, _webView.scrollView.contentSize.height, _webView.scrollView.contentInset.bottom);*/
}

// TODO RT: hacks end

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

/*- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
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

  // TODO RT:
  //scrollView.bounds = _webView.bounds;
  //RCTLogWarn(@"%zd, %zd, %zd", scrollView.contentInset.top, scrollView.contentInset.bottom, scrollView.contentSize.height);
}*/

#pragma mark - WKNavigationDelegate methods

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
  else if (_onLoadingFinish && !webView.loading && ![webView.URL.absoluteString isEqualToString:@"about:blank"]) {
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

@end
