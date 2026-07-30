#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

@interface WeatCamRootListController : PSListController
    <PHPickerViewControllerDelegate,
     UIDocumentPickerDelegate>
@property (nonatomic, strong) NSString *pickerTarget; // @"video" or @"image"
@end
