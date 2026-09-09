/// The public facade re-exports the platform-neutral contracts while owning the
/// single consumer entry point and platform bootstrap.
///
/// Swift 6.3 does not yet make `public import` a source-level re-export for
/// consumer name lookup, so this boundary uses the compiler's export form.
@_exported import WeaveUI
@_exported import WeaveAdapters
@_exported import Flux
