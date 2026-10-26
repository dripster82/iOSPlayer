Layered app icon for iOS 26's Liquid Glass rendering (Icon Composer document format).
Assets/r.png is the film-strip R cut from the flat AppIcon.png (background removed), on a near-black
solid fill, as one glass group with a neutral shadow and 50% translucency. Edit it by opening the
.icon in Icon Composer (Xcode → Open Developer Tool). The flat Assets.xcassets/AppIcon stays for
iOS 17 and 18, which cannot render layered icons; both share the name AppIcon, so Xcode picks the
layered one where it is supported.
