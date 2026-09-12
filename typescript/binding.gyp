{
  "targets": [{
    "target_name": "synurang_module_host",
    "sources": ["../src/node.c", "../src/module_host.c"],
    "include_dirs": ["../include"],
    "defines": ["SYNURANG_NODE_DYNAMIC", "NAPI_VERSION=8"],
    "conditions": [["OS=='linux'", {"libraries": ["-ldl", "-lpthread"]}]]
  }]
}
