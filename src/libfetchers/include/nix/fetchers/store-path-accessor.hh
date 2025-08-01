#pragma once

#include "nix/util/source-path.hh"

namespace nix {

class StorePath;
class Store;

ref<SourceAccessor> makeStorePathAccessor(ref<Store> store, const StorePath & storePath);

SourcePath getUnfilteredRootPath(CanonPath path);

} // namespace nix
