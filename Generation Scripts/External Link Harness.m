// Local regression fixture. Drive its buttons with native UI controls.
// Uses the same macOS URL-opening service as external desktop applications,
// with an explicit target so tests never change the default browser.
#import <Cocoa/Cocoa.h>

@interface LinkHarness : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@end
@implementation LinkHarness
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,440,215)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
      backing:NSBackingStoreBuffered defer:NO];
  self.window.title = @"Zen external-link regression test";
  NSArray *titles = @[@"Open test HTTPS", @"Open two test HTTPS pages", @"Open daily Zen HTTPS"];
  for (NSInteger index = 0; index < 3; index++) {
    NSButton *button = [NSButton buttonWithTitle:titles[index] target:self action:@selector(openLink:)];
    button.tag = index;
    button.frame = NSMakeRect(30,155-index*45,380,32);
    [self.window.contentView addSubview:button];
  }
  self.status = [NSTextField labelWithString:@"No browser request sent."];
  self.status.frame = NSMakeRect(30,15,380,28);
  [self.window.contentView addSubview:self.status];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}
- (void)openLink:(NSButton *)sender {
  NSURL *dist = [[[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
  NSURL *app = sender.tag == 2 ? [NSURL fileURLWithPath:@"/Applications/Zen.app"] :
      [dist URLByAppendingPathComponent:@"external-link-test/Zen (Dev - Links).app"];
  NSMutableArray *urls = [NSMutableArray arrayWithObject:[NSURL URLWithString:
      sender.tag == 2 ? @"https://example.com/?zen-external-harness=daily" : @"https://example.com/?zen-external-harness=one"]];
  if (sender.tag == 1) [urls addObject:[NSURL URLWithString:@"https://example.com/?zen-external-harness=two"]];
  NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
  configuration.activates = YES;
  [[NSWorkspace sharedWorkspace] openURLs:urls withApplicationAtURL:app configuration:configuration
      completionHandler:^(NSRunningApplication *application, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self.status.stringValue = error ? error.localizedDescription : @"macOS accepted the URL request.";
    });
  }];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end
int main(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    LinkHarness *delegate = [LinkHarness new];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
