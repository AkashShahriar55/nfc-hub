//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <nfc_hub/ccid_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) nfc_hub_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "CcidPlugin");
  ccid_plugin_register_with_registrar(nfc_hub_registrar);
}
