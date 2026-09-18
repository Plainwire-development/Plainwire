# Plainwire 2.0.3

2.0.3 is a bug-fix release for 2.0.2. It has no new features, no schema changes and no new configuration. It can be deployed over 2.0.2 as-is.

## Global banners display correctly

Once a global banner was published, clients showed it as a full-screen overlay instead of a bar at the top of the window. The browser console also filled with `TypeError: undefined is not an object (evaluating 'domNode.childNodes')`.

The client inserted the banner as the first element of `<body>`. The Plainwire interface manages every element in `<body>` by position, so it treated the banner as its own root element. It then rendered the whole app inside the fixed-position banner and failed on each later update. The banner is now placed outside `<body>`, so it shows as a bar again, with the app laid out below it.

## Banner links show without a label

The control plane marks a banner's link label as optional, but clients only showed the link when a label was set. A banner with a link but no label now shows the link as **Learn more**.

## Bot SDK version

The Erlang bot SDK (`sdk/erlang`) now reports version 2.0.3, in line with the server. The SDK code has not changed since 2.0.0.

## Known issues

The known issues listed in the [2.0.1 release notes](RELEASE_NOTES_2.0.1.md) still apply.
