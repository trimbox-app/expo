<p>
  <a href="https://docs.expo.dev/versions/latest/sdk/media-library/">
    <img
      src="../../.github/resources/expo-media-library.svg"
      alt="expo-media-library"
      height="64" />
  </a>
</p>

Provides access to user's media library.

# API documentation

- [Documentation for the latest stable release](https://docs.expo.dev/versions/latest/sdk/media-library/)
- [Documentation for the main branch](https://docs.expo.dev/versions/unversioned/sdk/media-library/)

# Installation in managed Expo projects

For [managed](https://docs.expo.dev/archive/managed-vs-bare/) Expo projects, please follow the installation instructions in the [API documentation for the latest stable release](https://docs.expo.dev/versions/latest/sdk/media-library/).

# Installation in bare React Native projects

For bare React Native projects, you must ensure that you have [installed and configured the `expo` package](https://docs.expo.dev/bare/installing-expo-modules/) before continuing.

### Add the package to your npm dependencies

```
npx expo install expo-media-library
```

### Configure for Android

This package automatically adds the `READ_EXTERNAL_STORAGE` and `WRITE_EXTERNAL_STORAGE` permissions. They are used when accessing the user's images or videos.

```xml
<!-- Added permissions -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
```

If you'd like to access asset location (latitude and longitude EXIF tags), you have to add `ACCESS_MEDIA_LOCATION` permission to the `AndroidManifest.xml`:

```xml
<!-- Add this to AndroidManifest.xml -->
<uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION" />
```

Starting with Android 10, the concept of [scoped storage](https://developer.android.com/training/data-storage#scoped-storage) is introduced. Currently, to make `expo-media-library` working with that change, you have to add `android:requestLegacyExternalStorage="true"` to `AndroidManifest.xml`:

```xml
<manifest ... >
  <application android:requestLegacyExternalStorage="true" ... >
    ...
  </application>
</manifest>
```

### Configure for iOS

Add `NSPhotoLibraryUsageDescription`, and `NSPhotoLibraryAddUsageDescription` keys to your `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Give $(PRODUCT_NAME) permission to access your photos</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Give $(PRODUCT_NAME) permission to save photos</string>
```

Run `npx pod-install` after installing the npm package.

# Contributing

Contributions are very welcome! Please refer to guidelines described in the [contributing guide](https://github.com/expo/expo#contributing).

# David's Steps to Publish a New Version:

## 1. Update the Version in package.json:

Increment the version number in your package.json file. This ensures that your new changes are recognized as a new version.

```json
{
  "version": "16.0.6"
}
```

## 2. Commit and Tag the New Version:

Commit your changes and create a tag that matches the new version number. This tag is crucial because the podspec file references the tag when pulling the source.

Run the following from packages/expo-media-library:

```bash
git add .
git commit -m "Updated ExpoMediaLibrary podspec with custom source"
git tag 16.0.25
git push origin --tags
```

## 3. Publish the New Version to GitHub Packages:

After tagging, you can publish your package using npm.

```bash
npm publish --registry=https://npm.pkg.github.com
```
