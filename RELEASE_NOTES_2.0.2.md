# Plainwire 2.0.2

2.0.2 is a bug-fix release for 2.0.1. It has no new features, no schema changes and no new configuration. It can be deployed over 2.0.1 as-is.

## Global banners can be published from the control plane

In the service control plane, the **Publish banner** and **Save banner** buttons in the global banner editor did nothing. The button was rendered in the dialog footer, outside the banner form, so clicking it never submitted the form. It is now linked to the form, so new banners publish and existing banners save as intended. The banner API itself was unaffected.

## Dismissing a confirmation now cancels it

Closing a control-plane confirmation dialog with ×, Escape or a click outside it now counts as **Cancel**. Before, the pending action was left unresolved: for example, dismissing "Change operator role?" left the role dropdown showing a role that was never applied.

## Known issues

The known issues listed in the [2.0.1 release notes](RELEASE_NOTES_2.0.1.md) still apply.
