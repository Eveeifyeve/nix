#include "nix/fetchers/fetchers.hh"
#include "nix/store/store-api.hh"
#include "nix/util/archive.hh"
#include "nix/fetchers/store-path-accessor.hh"
#include "nix/fetchers/cache.hh"
#include "nix/fetchers/fetch-to-store.hh"
#include "nix/fetchers/fetch-settings.hh"

namespace nix::fetchers {

struct PathInputScheme : InputScheme
{
    std::optional<Input> inputFromURL(const Settings & settings, const ParsedURL & url, bool requireTree) const override
    {
        if (url.scheme != "path")
            return {};

        if (url.authority && *url.authority != "")
            throw Error("path URL '%s' should not have an authority ('%s')", url, *url.authority);

        Input input{settings};
        input.attrs.insert_or_assign("type", "path");
        input.attrs.insert_or_assign("path", url.path);

        for (auto & [name, value] : url.query)
            if (name == "rev" || name == "narHash")
                input.attrs.insert_or_assign(name, value);
            else if (name == "revCount" || name == "lastModified") {
                if (auto n = string2Int<uint64_t>(value))
                    input.attrs.insert_or_assign(name, *n);
                else
                    throw Error("path URL '%s' has invalid parameter '%s'", url, name);
            } else
                throw Error("path URL '%s' has unsupported parameter '%s'", url, name);

        return input;
    }

    std::string_view schemeName() const override
    {
        return "path";
    }

    StringSet allowedAttrs() const override
    {
        return {
            "path",
            /* Allow the user to pass in "fake" tree info
               attributes. This is useful for making a pinned tree work
               the same as the repository from which is exported (e.g.
               path:/nix/store/...-source?lastModified=1585388205&rev=b0c285...).
             */
            "rev",
            "revCount",
            "lastModified",
            "narHash",
        };
    }

    std::optional<Input> inputFromAttrs(const Settings & settings, const Attrs & attrs) const override
    {
        getStrAttr(attrs, "path");

        Input input{settings};
        input.attrs = attrs;
        return input;
    }

    ParsedURL toURL(const Input & input) const override
    {
        auto query = attrsToQuery(input.attrs);
        query.erase("path");
        query.erase("type");
        query.erase("__final");
        return ParsedURL{
            .scheme = "path",
            .path = getStrAttr(input.attrs, "path"),
            .query = query,
        };
    }

    std::optional<std::filesystem::path> getSourcePath(const Input & input) const override
    {
        return getAbsPath(input);
    }

    void putFile(
        const Input & input,
        const CanonPath & path,
        std::string_view contents,
        std::optional<std::string> commitMsg) const override
    {
        writeFile(getAbsPath(input) / path.rel(), contents);
    }

    std::optional<std::string> isRelative(const Input & input) const override
    {
        auto path = getStrAttr(input.attrs, "path");
        if (isAbsolute(path))
            return std::nullopt;
        else
            return path;
    }

    bool isLocked(const Input & input) const override
    {
        return (bool) input.getNarHash();
    }

    std::filesystem::path getAbsPath(const Input & input) const
    {
        auto path = getStrAttr(input.attrs, "path");

        if (isAbsolute(path))
            return canonPath(path);

        throw Error("cannot fetch input '%s' because it uses a relative path", input.to_string());
    }

    std::pair<ref<SourceAccessor>, Input> getAccessor(ref<Store> store, const Input & _input) const override
    {
        Input input(_input);
        auto path = getStrAttr(input.attrs, "path");

        auto absPath = getAbsPath(input);

        Activity act(*logger, lvlTalkative, actUnknown, fmt("copying %s to the store", absPath));

        // FIXME: check whether access to 'path' is allowed.
        auto storePath = store->maybeParseStorePath(absPath.string());

        if (storePath)
            store->addTempRoot(*storePath);

        time_t mtime = 0;
        if (!storePath || storePath->name() != "source" || !store->isValidPath(*storePath)) {
            // FIXME: try to substitute storePath.
            auto src = sinkToSource(
                [&](Sink & sink) { mtime = dumpPathAndGetMtime(absPath.string(), sink, defaultPathFilter); });
            storePath = store->addToStoreFromDump(*src, "source");
        }

        // To avoid copying the path again to the /nix/store, we need to add a cache entry.
        ContentAddressMethod method = ContentAddressMethod::Raw::NixArchive;
        auto fp = getFingerprint(store, input);
        if (fp) {
            auto cacheKey = makeFetchToStoreCacheKey(input.getName(), *fp, method, "/");
            input.settings->getCache()->upsert(cacheKey, *store, {}, *storePath);
        }

        /* Trust the lastModified value supplied by the user, if
           any. It's not a "secure" attribute so we don't care. */
        if (!input.getLastModified())
            input.attrs.insert_or_assign("lastModified", uint64_t(mtime));

        return {makeStorePathAccessor(store, *storePath), std::move(input)};
    }

    std::optional<std::string> getFingerprint(ref<Store> store, const Input & input) const override
    {
        if (isRelative(input))
            return std::nullopt;

        /* If this path is in the Nix store, use the hash of the
           store object and the subpath. */
        auto path = getAbsPath(input);
        try {
            auto [storePath, subPath] = store->toStorePath(path.string());
            auto info = store->queryPathInfo(storePath);
            return fmt("path:%s:%s", info->narHash.to_string(HashFormat::Base16, false), subPath);
        } catch (Error &) {
            return std::nullopt;
        }
    }

    std::optional<ExperimentalFeature> experimentalFeature() const override
    {
        return Xp::Flakes;
    }
};

static auto rPathInputScheme = OnStartup([] { registerInputScheme(std::make_unique<PathInputScheme>()); });

} // namespace nix::fetchers
