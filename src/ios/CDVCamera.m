/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVCamera.h"
#import "CDVJpegHeaderWriter.h"
#import "UIImage+CropScaleOrientation.h"
#import <ImageIO/CGImageProperties.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/CGImageSource.h>
#import <ImageIO/CGImageProperties.h>
#import <ImageIO/CGImageDestination.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <objc/message.h>

#ifndef __CORDOVA_4_0_0
    #import <Cordova/NSData+Base64.h>
#endif

#define CDV_PHOTO_PREFIX @"cdv_photo_"

static NSSet* org_apache_cordova_validArrowDirections;

static NSString* toBase64(NSData* data) {
    SEL s1 = NSSelectorFromString(@"cdv_base64EncodedString");
    SEL s2 = NSSelectorFromString(@"base64EncodedString");
    SEL s3 = NSSelectorFromString(@"base64EncodedStringWithOptions:");

    if ([data respondsToSelector:s1]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s1];
        return func(data, s1);
    } else if ([data respondsToSelector:s2]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s2];
        return func(data, s2);
    } else if ([data respondsToSelector:s3]) {
        NSString* (*func)(id, SEL, NSUInteger) = (void *)[data methodForSelector:s3];
        return func(data, s3, 0);
    } else {
        return nil;
    }
}

@implementation CDVPictureOptions

+ (instancetype) createFromTakePictureArguments:(CDVInvokedUrlCommand*)command
{
    CDVPictureOptions* pictureOptions = [[CDVPictureOptions alloc] init];

    pictureOptions.quality = [command argumentAtIndex:0 withDefault:@(50)];
    pictureOptions.destinationType = [[command argumentAtIndex:1 withDefault:@(DestinationTypeFileUri)] unsignedIntegerValue];
    pictureOptions.sourceType = [[command argumentAtIndex:2 withDefault:@(UIImagePickerControllerSourceTypeCamera)] unsignedIntegerValue];

    NSNumber* targetWidth = [command argumentAtIndex:3 withDefault:nil];
    NSNumber* targetHeight = [command argumentAtIndex:4 withDefault:nil];
    pictureOptions.targetSize = CGSizeMake(0, 0);
    if ((targetWidth != nil) && (targetHeight != nil)) {
        pictureOptions.targetSize = CGSizeMake([targetWidth floatValue], [targetHeight floatValue]);
    }

    pictureOptions.encodingType = [[command argumentAtIndex:5 withDefault:@(EncodingTypeJPEG)] unsignedIntegerValue];
    pictureOptions.mediaType = [[command argumentAtIndex:6 withDefault:@(MediaTypePicture)] unsignedIntegerValue];
    pictureOptions.allowsEditing = [[command argumentAtIndex:7 withDefault:@(NO)] boolValue];
    pictureOptions.correctOrientation = [[command argumentAtIndex:8 withDefault:@(NO)] boolValue];
    pictureOptions.saveToPhotoAlbum = [[command argumentAtIndex:9 withDefault:@(NO)] boolValue];
    pictureOptions.popoverOptions = [command argumentAtIndex:10 withDefault:nil];
    pictureOptions.cameraDirection = [[command argumentAtIndex:11 withDefault:@(UIImagePickerControllerCameraDeviceRear)] unsignedIntegerValue];
    
    pictureOptions.popoverSupported = NO;
    pictureOptions.usesGeolocation = NO;
    
    // Only if source is Camera && opt set
    pictureOptions.showLibraryButton = (pictureOptions.sourceType == UIImagePickerControllerSourceTypeCamera) && [[command argumentAtIndex:12 withDefault:@(NO)] boolValue];
    
    
    return pictureOptions;
}

@end


@interface CDVCamera ()

@property (readwrite, assign) BOOL hasPendingOperation;

@end

@implementation CDVCamera

+ (void)initialize
{
    org_apache_cordova_validArrowDirections = [[NSSet alloc] initWithObjects:[NSNumber numberWithInt:UIPopoverArrowDirectionUp], [NSNumber numberWithInt:UIPopoverArrowDirectionDown], [NSNumber numberWithInt:UIPopoverArrowDirectionLeft], [NSNumber numberWithInt:UIPopoverArrowDirectionRight], [NSNumber numberWithInt:UIPopoverArrowDirectionAny], nil];
}

@synthesize hasPendingOperation, pickerController, locationManager;

- (NSURL*) urlTransformer:(NSURL*)url
{
    NSURL* urlToTransform = url;

    // for backwards compatibility - we check if this property is there
    SEL sel = NSSelectorFromString(@"urlTransformer");
    if ([self.commandDelegate respondsToSelector:sel]) {
        // grab the block from the commandDelegate
        NSURL* (^urlTransformer)(NSURL*) = ((id(*)(id, SEL))objc_msgSend)(self.commandDelegate, sel);
        // if block is not null, we call it
        if (urlTransformer) {
            urlToTransform = urlTransformer(url);
        }
    }

    return urlToTransform;
}

- (BOOL)usesGeolocation
{
    id useGeo = [self.commandDelegate.settings objectForKey:[@"CameraUsesGeolocation" lowercaseString]];
    return [(NSNumber*)useGeo boolValue];
}

- (BOOL)popoverSupported
{
    return (NSClassFromString(@"UIPopoverController") != nil) &&
           (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
}

- (void)takePicture:(CDVInvokedUrlCommand*)command
{
    self.hasPendingOperation = YES;

    __weak CDVCamera* weakSelf = self;

    [self.commandDelegate runInBackground:^{

        CDVPictureOptions* pictureOptions = [CDVPictureOptions createFromTakePictureArguments:command];
        pictureOptions.popoverSupported = [weakSelf popoverSupported];
        pictureOptions.usesGeolocation = [weakSelf usesGeolocation];
        pictureOptions.cropToSize = NO;

        BOOL hasCamera = [UIImagePickerController isSourceTypeAvailable:pictureOptions.sourceType];
        if (!hasCamera) {
            NSLog(@"Camera.getPicture: source type %lu not available.", (unsigned long)pictureOptions.sourceType);
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No camera available"];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        
        // If a popover is already open, close it; we only want one at a time.
        if (([[weakSelf pickerController] pickerPopoverController] != nil) && [[[weakSelf pickerController] pickerPopoverController] isPopoverVisible]) {
            [[[weakSelf pickerController] pickerPopoverController] dismissPopoverAnimated:YES];
            [[[weakSelf pickerController] pickerPopoverController] setDelegate:nil];
            [[weakSelf pickerController] setPickerPopoverController:nil];
        }
        
        CDVCameraPicker* cameraPicker = [CDVCameraPicker createFromPictureOptions:pictureOptions];
        weakSelf.pickerController = cameraPicker;
        
        cameraPicker.delegate = weakSelf;
        cameraPicker.callbackId = command.callbackId;
        // we need to capture this state for memory warnings that dealloc this object
        cameraPicker.webView = weakSelf.webView;
        
        if ([weakSelf popoverSupported] && (pictureOptions.sourceType != UIImagePickerControllerSourceTypeCamera)) {
            if (cameraPicker.pickerPopoverController == nil) {
                cameraPicker.pickerPopoverController = [[NSClassFromString(@"UIPopoverController") alloc] initWithContentViewController:cameraPicker];
            }
            [weakSelf displayPopover:pictureOptions.popoverOptions];
            weakSelf.hasPendingOperation = NO;

        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.viewController presentViewController:cameraPicker animated:YES completion:^{
                    weakSelf.hasPendingOperation = NO;
                }];
            });
        }
    }];
}

- (void)repositionPopover:(CDVInvokedUrlCommand*)command
{
    NSDictionary* options = [command argumentAtIndex:0 withDefault:nil];

    [self displayPopover:options];
}

- (NSInteger)integerValueForKey:(NSDictionary*)dict key:(NSString*)key defaultValue:(NSInteger)defaultValue
{
    NSInteger value = defaultValue;

    NSNumber* val = [dict valueForKey:key];  // value is an NSNumber

    if (val != nil) {
        value = [val integerValue];
    }
    return value;
}

- (void)displayPopover:(NSDictionary*)options
{
    NSInteger x = 0;
    NSInteger y = 32;
    NSInteger width = 320;
    NSInteger height = 480;
    UIPopoverArrowDirection arrowDirection = UIPopoverArrowDirectionAny;

    if (options) {
        x = [self integerValueForKey:options key:@"x" defaultValue:0];
        y = [self integerValueForKey:options key:@"y" defaultValue:32];
        width = [self integerValueForKey:options key:@"width" defaultValue:320];
        height = [self integerValueForKey:options key:@"height" defaultValue:480];
        arrowDirection = [self integerValueForKey:options key:@"arrowDir" defaultValue:UIPopoverArrowDirectionAny];
        if (![org_apache_cordova_validArrowDirections containsObject:[NSNumber numberWithUnsignedInteger:arrowDirection]]) {
            arrowDirection = UIPopoverArrowDirectionAny;
        }
    }

    [[[self pickerController] pickerPopoverController] setDelegate:self];
    [[[self pickerController] pickerPopoverController] presentPopoverFromRect:CGRectMake(x, y, width, height)
                                                                 inView:[self.webView superview]
                                               permittedArrowDirections:arrowDirection
                                                               animated:YES];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    if([navigationController isKindOfClass:[UIImagePickerController class]]){
        UIImagePickerController* cameraPicker = (UIImagePickerController*)navigationController;

        if(![cameraPicker.mediaTypes containsObject:(NSString*)kUTTypeImage]){
            [viewController.navigationItem setTitle:NSLocalizedString(@"Videos", nil)];
        }
    }
}

- (void)cleanup:(CDVInvokedUrlCommand*)command
{
    // empty the tmp directory
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError* err = nil;
    BOOL hasErrors = NO;

    // clear contents of NSTemporaryDirectory
    NSString* tempDirectoryPath = NSTemporaryDirectory();
    NSDirectoryEnumerator* directoryEnumerator = [fileMgr enumeratorAtPath:tempDirectoryPath];
    NSString* fileName = nil;
    BOOL result;

    while ((fileName = [directoryEnumerator nextObject])) {
        // only delete the files we created
        if (![fileName hasPrefix:CDV_PHOTO_PREFIX]) {
            continue;
        }
        NSString* filePath = [tempDirectoryPath stringByAppendingPathComponent:fileName];
        result = [fileMgr removeItemAtPath:filePath error:&err];
        if (!result && err) {
            NSLog(@"Failed to delete: %@ (error: %@)", filePath, err);
            hasErrors = YES;
        }
    }

    CDVPluginResult* pluginResult;
    if (hasErrors) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"One or more files failed to be deleted."];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)popoverControllerDidDismissPopover:(id)popoverController
{
    UIPopoverController* pc = (UIPopoverController*)popoverController;

    [pc dismissPopoverAnimated:YES];
    pc.delegate = nil;
    if (self.pickerController && self.pickerController.callbackId && self.pickerController.pickerPopoverController) {
        self.pickerController.pickerPopoverController = nil;
        NSString* callbackId = self.pickerController.callbackId;
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no image selected"];   // error callback expects string ATM
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    self.hasPendingOperation = NO;
}

- (NSData*)processImage:(UIImage*)image info:(NSDictionary*)info options:(CDVPictureOptions*)options
{
    NSData* data = nil;

    switch (options.encodingType) {
        case EncodingTypePNG:
            data = UIImagePNGRepresentation(image);
            break;
        case EncodingTypeJPEG:
        {
            if ((options.allowsEditing == NO) && (options.targetSize.width <= 0) && (options.targetSize.height <= 0) && (options.correctOrientation == NO) && (([options.quality integerValue] == 100) || (options.sourceType != UIImagePickerControllerSourceTypeCamera))){
                // use image unedited as requested , don't resize
                data = UIImageJPEGRepresentation(image, 1.0);
            } else {
                data = UIImageJPEGRepresentation(image, [options.quality floatValue] / 100.0f);
            }

            if (options.usesGeolocation) {
                NSDictionary* controllerMetadata = [info objectForKey:@"UIImagePickerControllerMediaMetadata"];
                if (controllerMetadata) {
                    self.data = data;
                    self.metadata = [[NSMutableDictionary alloc] init];

                    NSMutableDictionary* EXIFDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyExifDictionary]mutableCopy];
                    if (EXIFDictionary)	{
                        [self.metadata setObject:EXIFDictionary forKey:(NSString*)kCGImagePropertyExifDictionary];
                    }

                    if (IsAtLeastiOSVersion(@"8.0")) {
                        [[self locationManager] performSelector:NSSelectorFromString(@"requestWhenInUseAuthorization") withObject:nil afterDelay:0];
                    }
                    [[self locationManager] startUpdatingLocation];
                }
            }
        }
            break;
        default:
            break;
    };
    
    return data;
}

- (NSString*)tempFilePath:(NSString*)extension
{
    // NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];
    // Use Cache directory instead of temp directory to avoid removing the files when user closes the app
    NSString* cachePath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0];
    NSFileManager* fileMgr = [[NSFileManager alloc] init]; // recommended by Apple (vs [NSFileManager defaultManager]) to be threadsafe
    NSString* filePath;
    
    // generate unique file name
    int i = 1;
    do {
        filePath = [NSString stringWithFormat:@"%@/%@%03d.%@", cachePath, CDV_PHOTO_PREFIX, i++, extension];
    } while ([fileMgr fileExistsAtPath:filePath]);
    
    return filePath;
}

- (UIImage*)retrieveImage:(NSDictionary*)info options:(CDVPictureOptions*)options
{
    // get the image
    UIImage* image = nil;
    if (options.allowsEditing && [info objectForKey:UIImagePickerControllerEditedImage]) {
        image = [info objectForKey:UIImagePickerControllerEditedImage];
    } else {
        image = [info objectForKey:UIImagePickerControllerOriginalImage];
    }

    if (options.correctOrientation) {
        image = [image imageCorrectedForCaptureOrientation];
    }

    UIImage* scaledImage = nil;

    if ((options.targetSize.width > 0) && (options.targetSize.height > 0)) {
        // if cropToSize, resize image and crop to target size, otherwise resize to fit target without cropping
        if (options.cropToSize) {
            scaledImage = [image imageByScalingAndCroppingForSize:options.targetSize];
        } else {
            scaledImage = [image imageByScalingNotCroppingForSize:options.targetSize];
        }
    }
    
    return (scaledImage == nil ? image : scaledImage);
}

- (CDVPluginResult*)resultForImage:(CDVPictureOptions*)options info:(NSDictionary*)info
{
    CDVPluginResult* result = nil;
    BOOL saveToPhotoAlbum = options.saveToPhotoAlbum;
    UIImage* image = nil;

    switch (options.destinationType) {
        case DestinationTypeNativeUri:
        {
            NSURL* url = (NSURL*)[info objectForKey:UIImagePickerControllerReferenceURL];
            NSString* nativeUri = [[self urlTransformer:url] absoluteString];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:nativeUri];
            saveToPhotoAlbum = NO;
        }
            break;
        case DestinationTypeFileUri:
        {
            image = [self retrieveImage:info options:options];
            NSData* data = [self processImage:image info:info options:options];
            if (data) {

                NSString* extension = options.encodingType == EncodingTypePNG? @"png" : @"jpg";
                NSString* filePath = [self tempFilePath:extension];
                NSError* err = nil;

                // save file
                if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                } else {
                    result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
                }
            }
        }
            break;
        case DestinationTypeDataUrl:
        {
            image = [self retrieveImage:info options:options];
            NSData* data = [self processImage:image info:info options:options];
            if (data)  {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:toBase64(data)];
            }
        }
            break;
        default:
            break;
    };
    
    if (saveToPhotoAlbum && image && [info objectForKey:UIImagePickerControllerReferenceURL] == NULL) {
        ALAssetsLibrary* library = [ALAssetsLibrary new];
        [library writeImageToSavedPhotosAlbum:image.CGImage orientation:(ALAssetOrientation)(image.imageOrientation) completionBlock:nil];
    }
    
    return result;
}

- (CDVPluginResult*)resultForVideo:(NSDictionary*)info
{
    NSString* moviePath = [[info objectForKey:UIImagePickerControllerMediaURL] absoluteString];
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:moviePath];
}

- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary*)info
{
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVCamera* weakSelf = self;
    
    dispatch_block_t invoke = ^(void) {
        __block CDVPluginResult* result = nil;
        
        NSString* mediaType = [info objectForKey:UIImagePickerControllerMediaType];
        if ([mediaType isEqualToString:(NSString*)kUTTypeImage]) {
            result = [self resultForImage:cameraPicker.pictureOptions info:info];
        }
        else {
            result = [self resultForVideo:info];
        }
        
        if (result) {
            [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];
            weakSelf.hasPendingOperation = NO;
            weakSelf.pickerController = nil;
        }
    };
    
    if (cameraPicker.pictureOptions.popoverSupported && (cameraPicker.pickerPopoverController != nil)) {
        [cameraPicker.pickerPopoverController dismissPopoverAnimated:YES];
        cameraPicker.pickerPopoverController.delegate = nil;
        cameraPicker.pickerPopoverController = nil;
        invoke();
    } else {
        [[cameraPicker presentingViewController] dismissViewControllerAnimated:YES completion:invoke];
    }
}

// older api calls newer didFinishPickingMediaWithInfo
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingImage:(UIImage*)image editingInfo:(NSDictionary*)editingInfo
{
    NSDictionary* imageInfo = [NSDictionary dictionaryWithObject:image forKey:UIImagePickerControllerOriginalImage];

    [self imagePickerController:picker didFinishPickingMediaWithInfo:imageInfo];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker
{
    // Switch the UIImagePickerController to show camera
//    picker.sourceType = UIImagePickerControllerSourceTypeCamera;
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVCamera* weakSelf = self;
    
    dispatch_block_t invoke = ^ (void) {
        CDVPluginResult* result;
//        if ([ALAssetsLibrary authorizationStatus] == ALAuthorizationStatusAuthorized) {
//            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no image selected"];
//        } else {
//            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to assets"];
//        }
        
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"Library"];
        
        [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];
        
        weakSelf.hasPendingOperation = NO;
        weakSelf.pickerController = nil;
    };
    
    [[cameraPicker presentingViewController] dismissViewControllerAnimated:NO completion:invoke];
}

- (CLLocationManager*)locationManager
{
    if (locationManager != nil) {
        return locationManager;
    }
    
    locationManager = [[CLLocationManager alloc] init];
    [locationManager setDesiredAccuracy:kCLLocationAccuracyNearestTenMeters];
    [locationManager setDelegate:self];
    
    return locationManager;
}

- (void)locationManager:(CLLocationManager*)manager didUpdateToLocation:(CLLocation*)newLocation fromLocation:(CLLocation*)oldLocation
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    NSMutableDictionary *GPSDictionary = [[NSMutableDictionary dictionary] init];

    CLLocationDegrees latitude  = newLocation.coordinate.latitude;
    CLLocationDegrees longitude = newLocation.coordinate.longitude;

    // latitude
    if (latitude < 0.0) {
        latitude = latitude * -1.0f;
        [GPSDictionary setObject:@"S" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    } else {
        [GPSDictionary setObject:@"N" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:latitude] forKey:(NSString*)kCGImagePropertyGPSLatitude];

    // longitude
    if (longitude < 0.0) {
        longitude = longitude * -1.0f;
        [GPSDictionary setObject:@"W" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    else {
        [GPSDictionary setObject:@"E" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:longitude] forKey:(NSString*)kCGImagePropertyGPSLongitude];

    // altitude
    CGFloat altitude = newLocation.altitude;
    if (!isnan(altitude)){
        if (altitude < 0) {
            altitude = -altitude;
            [GPSDictionary setObject:@"1" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        } else {
            [GPSDictionary setObject:@"0" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        }
        [GPSDictionary setObject:[NSNumber numberWithFloat:altitude] forKey:(NSString *)kCGImagePropertyGPSAltitude];
    }

    // Time and date
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSSSSS"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSTimeStamp];
    [formatter setDateFormat:@"yyyy:MM:dd"];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSDateStamp];

    [self.metadata setObject:GPSDictionary forKey:(NSString *)kCGImagePropertyGPSDictionary];
    [self imagePickerControllerReturnImageResult];
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    [self imagePickerControllerReturnImageResult];
}

- (void)imagePickerControllerReturnImageResult
{
    CDVPictureOptions* options = self.pickerController.pictureOptions;
    CDVPluginResult* result = nil;

    if (self.metadata) {
        CGImageSourceRef sourceImage = CGImageSourceCreateWithData((__bridge CFDataRef)self.data, NULL);
        CFStringRef sourceType = CGImageSourceGetType(sourceImage);

        CGImageDestinationRef destinationImage = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)self.data, sourceType, 1, NULL);
        CGImageDestinationAddImageFromSource(destinationImage, sourceImage, 0, (__bridge CFDictionaryRef)self.metadata);
        CGImageDestinationFinalize(destinationImage);

        CFRelease(sourceImage);
        CFRelease(destinationImage);
    }

    switch (options.destinationType) {
        case DestinationTypeFileUri:
        {
            NSError* err = nil;
            NSString* extension = self.pickerController.pictureOptions.encodingType == EncodingTypePNG ? @"png":@"jpg";
            NSString* filePath = [self tempFilePath:extension];

            // save file
            if (![self.data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
            }
            else {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
            }
        }
            break;
        case DestinationTypeDataUrl:
        {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:toBase64(self.data)];
        }
            break;
        case DestinationTypeNativeUri:
        default:
            break;
    };

    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:self.pickerController.callbackId];
    }

    self.hasPendingOperation = NO;
    self.pickerController = nil;
    self.data = nil;
    self.metadata = nil;

    if (options.saveToPhotoAlbum) {
        ALAssetsLibrary *library = [ALAssetsLibrary new];
        [library writeImageDataToSavedPhotosAlbum:self.data metadata:self.metadata completionBlock:nil];
    }
}

@end

@implementation CDVCameraPicker

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (UIViewController*)childViewControllerForStatusBarHidden
{
    return nil;
}
    
- (void)viewWillAppear:(BOOL)animated
{
    SEL sel = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:sel]) {
        [self performSelector:sel withObject:nil afterDelay:0];
    }
    
    if (self.pictureOptions.showLibraryButton) {
        // Register for notifications when the user captures an image
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleNotification:) name:@"_UIImagePickerControllerUserDidCaptureItem"object:nil];

        // Register for notifications when the user returns to the camera view to take another picture
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleNotification:) name:@"_UIImagePickerControllerUserDidRejectItem" object:nil];
    }
    
    [super viewWillAppear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
    if (self.pictureOptions.showLibraryButton) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }

    [super viewDidDisappear:animated];
}

- (IBAction)cancelPhoto {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleNotification:(NSNotification*)notification {
    if ([[notification name] isEqualToString:@"_UIImagePickerControllerUserDidCaptureItem"]) {
       // Remove overlay, so that it is not available on the preview view;
       [self.cameraOverlayView setHidden:YES];
    }
    else if ([[notification name] isEqualToString:@"_UIImagePickerControllerUserDidRejectItem"]) {
        // Retake button pressed on preview. Add overlay, so that is available on the camera again
        [self.cameraOverlayView setHidden:NO];
        }
}

// Create an overlay view that include a button allowing quick access to choose an image from the library
- (UIView*)createOverlayView {
    UIView* overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    UIToolbar *toolBar=[[UIToolbar alloc] initWithFrame:self.view.bounds];
    toolBar.barStyle =  UIBarStyleBlack;
    
    // Make the background transparent so the existing UI shows through
    overlay.opaque = NO;
    overlay.backgroundColor = [UIColor clearColor];
    
    // Make sure the view auto-resizes when the orientation changes
    overlay.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    
    // Add a button to allow access to the camera roll
    UIButton *libraryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    libraryButton.backgroundColor = [UIColor clearColor];
    
    // For now, set the title to (localized) "Library" so it appears even if we can't get the most recent picture
    [libraryButton setTitle:NSLocalizedString(@"Library", nil) forState:UIControlStateNormal];
    libraryButton.imageView.contentMode = UIViewContentModeScaleAspectFill;
    
    [libraryButton addTarget:self
                      action:@selector(switchToCameraRoll)
            forControlEvents:UIControlEventTouchUpInside];
    
    [libraryButton setTranslatesAutoresizingMaskIntoConstraints:NO];
    
    // Set the image to the most recent one in the Camera Roll
    [self setImageFromCameraRoll:libraryButton];
    
    UIButton *captureButton =  [UIButton buttonWithType:UIButtonTypeCustom];
    [captureButton addTarget:self
                      action:@selector(takePicture)
            forControlEvents:UIControlEventTouchUpInside];
    
    UIImage *captureImage = [[UIImage imageNamed:@"capture.png"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [captureButton setImage:captureImage forState:UIControlStateNormal];
    
    [captureButton setTranslatesAutoresizingMaskIntoConstraints:NO];
    
    UIButton *cancelButton =  [UIButton buttonWithType:UIButtonTypeCustom];
    [cancelButton addTarget:self
                     action:@selector(cancelPhoto)
           forControlEvents:UIControlEventTouchUpInside];
    [cancelButton setFrame:CGRectMake(0, 0, 100, 31)];
    [cancelButton.titleLabel setFont:[UIFont fontWithName:@"ArialMT" size:16.0]];
    cancelButton.backgroundColor = [UIColor clearColor];
    [cancelButton setTitle:NSLocalizedString(@"Cancel", nil) forState:UIControlStateNormal];
    
    [cancelButton setTranslatesAutoresizingMaskIntoConstraints:NO];
    
    [toolBar setTranslatesAutoresizingMaskIntoConstraints:NO];
    
    // Add the toolbar to the overlay
    [overlay addSubview:toolBar];
    
    // Add the library button to the overlay
    [overlay addSubview:libraryButton];
    
    // Add the capture button to the overlay
    [overlay addSubview:captureButton];
    
    // Add the cancel button to the overlay
    [overlay addSubview:cancelButton];
    
    int rightOffsetLibrary = -15, rightOffsetCameraButton = -15, rightOffsetCancelButton = -15;
    NSLayoutConstraint *bottomConstraintLibraryButton, *bottomConstraintCaptureButton, *bottomConstraintCancelButton, *bottomConstraintToolbar;
    
    UIScreen* mainScreen = [UIScreen mainScreen];
    CGFloat mainScreenHeight = mainScreen.bounds.size.height;
    CGFloat mainScreenWidth = mainScreen.bounds.size.width;
    
    // On screens >480px tall, the controls are bigger
    int limit = MAX(mainScreenHeight,mainScreenWidth);
    
    // Positioning for iPad
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        bottomConstraintLibraryButton = [NSLayoutConstraint constraintWithItem:libraryButton
                                                                     attribute:NSLayoutAttributeCenterY
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:overlay
                                                                     attribute:NSLayoutAttributeCenterY
                                                                    multiplier:1.75
                                                                      constant:0];
        
        bottomConstraintCaptureButton = [NSLayoutConstraint constraintWithItem:captureButton
                                                                     attribute:NSLayoutAttributeCenterY
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:overlay
                                                                     attribute:NSLayoutAttributeCenterY
                                                                    multiplier:1.0
                                                                      constant:0];
        
        bottomConstraintCancelButton = [NSLayoutConstraint constraintWithItem:cancelButton
                                                                    attribute:NSLayoutAttributeCenterY
                                                                    relatedBy:NSLayoutRelationEqual
                                                                       toItem:overlay
                                                                    attribute:NSLayoutAttributeCenterY
                                                                   multiplier:0.25
                                                                     constant:0];
        
        bottomConstraintToolbar = [NSLayoutConstraint constraintWithItem:toolBar
                                                                     attribute:NSLayoutAttributeCenterX
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:overlay
                                                                     attribute:NSLayoutAttributeCenterX
                                                                    multiplier:1.0
                                                                      constant:0];
        
        [overlay addConstraints:@[
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeWidth
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:nil
                                                               attribute:NSLayoutAttributeNotAnAttribute
                                                              multiplier:1.0
                                                                constant:90.0],
                                  
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeHeight
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:nil
                                                               attribute:NSLayoutAttributeNotAnAttribute
                                                              multiplier:1.0
                                                                constant:limit],
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeRight
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:overlay
                                                               attribute:NSLayoutAttributeRight
                                                              multiplier:1
                                                                constant:0.0]
                                  ]];
        
    }
    // Positioning for iPhone
    else {
        int bottomOffset = -8;
        
        // Determine the bottom offset based on the device screen size
        switch (limit) {
            case 480:
            case 568:
                bottomOffset = -14;
                break;
                
            case 667:
                bottomOffset = -22;
                break;
                
            case 736:
            default:
                bottomOffset = -33;
                break;
                
        }
        rightOffsetLibrary = -13;
        rightOffsetCameraButton = -( (mainScreenWidth - 60) / 2); // center the camera button
        rightOffsetCancelButton = -( mainScreenWidth - 60 - 13); // align the cancel button on right with -13 offset
        
        bottomConstraintLibraryButton = [NSLayoutConstraint constraintWithItem:libraryButton
                                                                     attribute:NSLayoutAttributeBottom
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:overlay
                                                                     attribute:NSLayoutAttributeBottom
                                                                    multiplier:1.0
                                                                      constant:bottomOffset];
        
        bottomConstraintCancelButton = [NSLayoutConstraint constraintWithItem:cancelButton
                                                                    attribute:NSLayoutAttributeBottom
                                                                    relatedBy:NSLayoutRelationEqual
                                                                       toItem:overlay
                                                                    attribute:NSLayoutAttributeBottom
                                                                   multiplier:1.0
                                                                     constant:bottomOffset];
        
        bottomConstraintCaptureButton = [NSLayoutConstraint constraintWithItem:captureButton
                                                                     attribute:NSLayoutAttributeBottom
                                                                     relatedBy:NSLayoutRelationEqual
                                                                        toItem:overlay
                                                                     attribute:NSLayoutAttributeBottom
                                                                    multiplier:1.0
                                                                      constant:bottomOffset];
        
        [overlay addConstraints:@[
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeWidth
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:nil
                                                               attribute:NSLayoutAttributeNotAnAttribute
                                                              multiplier:1.0
                                                                constant:limit],
                                  
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeHeight
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:nil
                                                               attribute:NSLayoutAttributeNotAnAttribute
                                                              multiplier:1.0
                                                                constant:90.0],
                                  [NSLayoutConstraint constraintWithItem:toolBar
                                                               attribute:NSLayoutAttributeBottom
                                                               relatedBy:NSLayoutRelationEqual
                                                                  toItem:overlay
                                                               attribute:NSLayoutAttributeBottom
                                                              multiplier:1
                                                                constant:0.0]
                                  ]];
    }

    // Add auto-layout constraints to keep the size and position of the button correct on all devices
    [overlay addConstraints:@[
                              [NSLayoutConstraint constraintWithItem:libraryButton
                                                           attribute:NSLayoutAttributeWidth
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:libraryButton
                                                           attribute:NSLayoutAttributeHeight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:libraryButton
                                                           attribute:NSLayoutAttributeRight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:overlay
                                                           attribute:NSLayoutAttributeRight
                                                          multiplier:1
                                                            constant:rightOffsetLibrary],
                              bottomConstraintLibraryButton
                              ]];
    
    // Add auto-layout constraints to keep the size and position of the button correct on all devices
    [overlay addConstraints:@[
                              [NSLayoutConstraint constraintWithItem:captureButton
                                                           attribute:NSLayoutAttributeWidth
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:captureButton
                                                           attribute:NSLayoutAttributeHeight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:captureButton
                                                           attribute:NSLayoutAttributeRight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:overlay
                                                           attribute:NSLayoutAttributeRight
                                                          multiplier:1
                                                            constant:rightOffsetCameraButton],
                              bottomConstraintCaptureButton
                              ]];
    
    // Add auto-layout constraints to keep the size and position of the button correct on all devices
    [overlay addConstraints:@[
                              [NSLayoutConstraint constraintWithItem:cancelButton
                                                           attribute:NSLayoutAttributeWidth
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:cancelButton
                                                           attribute:NSLayoutAttributeHeight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:nil
                                                           attribute:NSLayoutAttributeNotAnAttribute
                                                          multiplier:1.0
                                                            constant:60.0],
                              
                              [NSLayoutConstraint constraintWithItem:cancelButton
                                                           attribute:NSLayoutAttributeRight
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:overlay
                                                           attribute:NSLayoutAttributeRight
                                                          multiplier:1
                                                            constant:rightOffsetCancelButton],
                              bottomConstraintCancelButton
                              ]];
    
    return overlay;
}

// Retrieves the last image from the camera roll, and sets it as the image for the library button
- (void)setImageFromCameraRoll:(UIButton*)button {
    // Make sure we have authorization to access it first, to avoid putting up an extra prompt right away
    ALAuthorizationStatus status = [ALAssetsLibrary authorizationStatus];
    
    if (status != ALAuthorizationStatusAuthorized) {
        return;
    }
    
    // Enumerate the assets, take the first image, and set it on the UIButton
    ALAssetsGroupEnumerationResultsBlock assetEnumBlock = ^(ALAsset *asset, NSUInteger index, BOOL *stop) {
        if (!asset) return;
        
        ALAssetRepresentation *repr = [asset defaultRepresentation];
        UIImage *img = [UIImage imageWithCGImage:[repr fullScreenImage]];
        [button setImage:img forState:UIControlStateNormal];
        
        // Call this on the UI thread so it updates immediately
        dispatch_async(dispatch_get_main_queue(), ^{
            [button setNeedsLayout];
        });
        
        *stop = YES;
    };
    
    ALAssetsLibraryGroupsEnumerationResultsBlock groupsEnumBlock = ^(ALAssetsGroup *group, BOOL *stop) {
        if (nil != group) {
            // Filter the group to only include photos
            [group setAssetsFilter:[ALAssetsFilter allPhotos]];
            
            // Enumerate assets in reverse to get most recent
            [group enumerateAssetsWithOptions:NSEnumerationReverse
                                   usingBlock:assetEnumBlock];
        }
        
        *stop = NO;
    };
    
    // Enumerate the assets library
    ALAssetsLibrary *assetsLibrary = [[ALAssetsLibrary alloc] init];
    [assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupSavedPhotos
                                 usingBlock:groupsEnumBlock
                               failureBlock:^(NSError *error) {
                                   NSLog(@"Camera: error enumerating library [%@]", error);
                               }];
}

- (void)switchToCameraRoll {
    // Switch the UIImagePickerController to show the saved photos album
//    self.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
   [self.delegate imagePickerControllerDidCancel:(UIImagePickerController *)self];
}


+ (instancetype) createFromPictureOptions:(CDVPictureOptions*)pictureOptions;
{
    CDVCameraPicker* cameraPicker = [[CDVCameraPicker alloc] init];
    cameraPicker.pictureOptions = pictureOptions;
    cameraPicker.sourceType = pictureOptions.sourceType;
    cameraPicker.allowsEditing = pictureOptions.allowsEditing;
    
    if (cameraPicker.sourceType == UIImagePickerControllerSourceTypeCamera) {
        // We only allow taking pictures (no video) in this API.
        cameraPicker.mediaTypes = @[(NSString*)kUTTypeImage];
        // We can only set the camera device if we're actually using the camera.
        cameraPicker.cameraDevice = pictureOptions.cameraDirection;
        cameraPicker.showsCameraControls = YES;
        
        // If enabled, show button to allow accessing library instead
        // For iOS 7+ only, as the UI for lower versions is different
        if (pictureOptions.showLibraryButton == YES && IsAtLeastiOSVersion(@"7.0")) {
            cameraPicker.cameraOverlayView = [cameraPicker createOverlayView];
            cameraPicker.showsCameraControls = NO;
            
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
               // Device's screen size (ignoring rotation intentionally):
               CGSize screenSize = [[UIScreen mainScreen] bounds].size;
            
               // iOS is going to calculate a size which constrains the 4:3 aspect ratio
               // to the screen size. We're basically mimicking that here to determine
               // what size the system will likely display the image at on screen.
               // NOTE: screenSize.width may seem odd in this calculation - but, remember,
               // the devices only take 4:3 images when they are oriented *sideways*.
               float cameraAspectRatio = 4.0 / 3.0;
               float imageWidth = floorf(screenSize.width * cameraAspectRatio);
               float scale = ceilf((screenSize.height / imageWidth) * 10.0) / 10.0;
            
               cameraPicker.cameraViewTransform = CGAffineTransformMakeScale(scale, scale);
            }
        }
        
    } else if (pictureOptions.mediaType == MediaTypeAll) {
        cameraPicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:cameraPicker.sourceType];
    } else {
        NSArray* mediaArray = @[(NSString*)(pictureOptions.mediaType == MediaTypeVideo ? kUTTypeMovie : kUTTypeImage)];
        cameraPicker.mediaTypes = mediaArray;
    }
    
    return cameraPicker;
}

@end