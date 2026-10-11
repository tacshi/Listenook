#include "include/desktop_drop/desktop_drop_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <sstream>
#include <algorithm>
#include <vector>

namespace {

    using FlutterMethodChannel = std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>;
    // 115Lab patch: targets share the plugin's channel instead of owning one,
    // so the plugin can attach a target to every window it is asked to.
    using ChannelRef = flutter::MethodChannel<flutter::EncodableValue> *;


    using namespace std::literals::string_literals;

    std::string ws2s(const std::wstring &wstr) {
        if (wstr.empty()) {
            return {};
        }
        size_t pos;
        size_t begin = 0;
        std::string ret;

        int size;
        pos = wstr.find(static_cast<wchar_t>(0), begin);
        while (pos != std::wstring::npos && begin < wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], pos - begin);
            size = WideCharToMultiByte(CP_UTF8,
                                       WC_ERR_INVALID_CHARS,
                                       &segment[0],
                                       (int) segment.size(),
                                       nullptr,
                                       0,
                                       nullptr,
                                       nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
            ret.append({0});
            begin = pos + 1;
            pos = wstr.find(static_cast<wchar_t>(0), begin);
        }
        if (begin <= wstr.length()) {
            std::wstring segment = std::wstring(&wstr[begin], wstr.length() - begin);
            size =
                    WideCharToMultiByte(CP_UTF8,
                                        WC_ERR_INVALID_CHARS,
                                        &segment[0],
                                        (int) segment.size(),
                                        nullptr,
                                        0,
                                        nullptr,
                                        nullptr);
            std::string converted = std::string(size, 0);
            WideCharToMultiByte(CP_UTF8,
                                WC_ERR_INVALID_CHARS,
                                &segment[0],
                                (int) segment.size(),
                                &converted[0],
                                (int) converted.size(),
                                nullptr,
                                nullptr);
            ret.append(converted);
        }

        return ret;
    }


    class DesktopDropTarget : public IDropTarget {
    public:

        DesktopDropTarget(ChannelRef channel, HWND window_handle);

        HRESULT DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT DragLeave() override;

        HRESULT Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) override;

        HRESULT QueryInterface(const IID &riid, void **ppvObject) override;

        ULONG AddRef() override;

        ULONG Release() override;

        virtual ~DesktopDropTarget();

        HWND window_handle() const { return window_handle_; }

    private:
        ChannelRef channel_;
        HWND window_handle_;
        LONG ref_count_;
        bool need_revoke_ole_initialize_;
    };

    class DesktopDropPlugin : public flutter::Plugin {

    public:
        static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

        explicit DesktopDropPlugin(FlutterMethodChannel channel);

        ~DesktopDropPlugin() override;

        // 115Lab patch: accepts drops on [window] (a top-level window or the
        // Flutter view inside it). Returns false for a window that is not a
        // live window of this process.
        bool Attach(HWND window);

    private:

        FlutterMethodChannel channel_;
        std::vector<DesktopDropTarget *> targets_;

    };

    DesktopDropPlugin::DesktopDropPlugin(FlutterMethodChannel channel) : channel_(std::move(channel)) {
        channel_->SetMethodCallHandler([this](const auto &call, auto result) {
            // 115Lab patch: `attachToWindow {handle: HWND as int}`. A
            // multi-view engine creates its windows after plugin registration,
            // when the registrar has no view to hand out.
            if (call.method_name() == "attachToWindow") {
                const auto *args = std::get_if<flutter::EncodableMap>(call.arguments());
                HWND window = nullptr;
                if (args) {
                    auto it = args->find(flutter::EncodableValue("handle"));
                    if (it != args->end()) {
                        window = reinterpret_cast<HWND>(static_cast<intptr_t>(it->second.LongValue()));
                    }
                }
                result->Success(flutter::EncodableValue(Attach(window)));
                return;
            }
            result->NotImplemented();
        });
    }

    DesktopDropPlugin::~DesktopDropPlugin() {
        for (auto *target : targets_) {
            target->Release();
        }
    }

    bool DesktopDropPlugin::Attach(HWND window) {
        DWORD owner = 0;
        if (window == nullptr || !IsWindow(window) ||
            GetWindowThreadProcessId(window, &owner) == 0 ||
            owner != GetCurrentProcessId()) {
            return false;
        }
        // Drops land on the Flutter view that fills the window's client area.
        HWND view = FindWindowExW(window, nullptr, L"FLUTTERVIEW", nullptr);
        HWND target_window = view != nullptr ? view : window;
        for (auto *target : targets_) {
            if (target->window_handle() == target_window) return true;
        }
        auto *target = new DesktopDropTarget(channel_.get(), target_window);
        target->AddRef();
        targets_.push_back(target);
        return true;
    }


    // static
    void DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarWindows *registrar) {
        auto channel =
                std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
                        registrar->messenger(), "desktop_drop",
                        &flutter::StandardMethodCodec::GetInstance());

        auto plugin = std::make_unique<DesktopDropPlugin>(std::move(channel));

        // 115Lab patch: attach now only when a view already exists; otherwise
        // the app attaches to its window with `attachToWindow`.
        if (registrar->GetView()) {
            plugin->Attach(GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT));
        }

        registrar->AddPlugin(std::move(plugin));
    }


    DesktopDropTarget::DesktopDropTarget(ChannelRef channel, HWND window_handle) : channel_(
            channel), window_handle_(window_handle), ref_count_(0), need_revoke_ole_initialize_(false) {
        auto ret = RegisterDragDrop(window_handle_, this);
        if (ret == E_OUTOFMEMORY) {
            OleInitialize(nullptr);
            ret = RegisterDragDrop(window_handle_, this);
            if (ret == 0) {
                need_revoke_ole_initialize_ = true;
            }
        }

        if (ret != 0) {
            std::cout << "RegisterDragDrop failed: " << ret << std::endl;
        }
    }

    HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("entered", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
        POINT point = {pt.x, pt.y};
        ScreenToClient(window_handle_, &point);
        channel_->InvokeMethod("updated", std::make_unique<flutter::EncodableValue>(
                flutter::EncodableList{
                        flutter::EncodableValue(double(point.x)),
                        flutter::EncodableValue(double(point.y))
                }
        ));
        return 0;
    }

    HRESULT DesktopDropTarget::DragLeave() {
        channel_->InvokeMethod("exited", std::make_unique<flutter::EncodableValue>());
        return 0;
    }

    HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {

        flutter::EncodableList list = {};

        // construct a FORMATETC object
        FORMATETC fmtetc = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM stgmed;

        // See if the dataobject contains any TEXT stored as a HGLOBAL
        if (pDataObj->QueryGetData(&fmtetc) == S_OK) {
            // Yippie! the data is there, so go get it!
            if (pDataObj->GetData(&fmtetc, &stgmed) == S_OK) {
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }

                // release the data using the COM API
                ReleaseStgMedium(&stgmed);
            }
        }
        channel_->InvokeMethod("performOperation", std::make_unique<flutter::EncodableValue>(list));

        return 0;
    }

    HRESULT DesktopDropTarget::QueryInterface(const IID &iid, void **ppvObject) {
        if (iid == IID_IDropTarget || iid == IID_IUnknown) {
            AddRef();
            *ppvObject = this;
            return S_OK;
        } else {
            *ppvObject = nullptr;
            return E_NOINTERFACE;
        }
    }

    ULONG DesktopDropTarget::AddRef() {
        return InterlockedIncrement(&ref_count_);
    }

    ULONG DesktopDropTarget::Release() {
        LONG count = InterlockedDecrement(&ref_count_);

        if (count == 0) {
            delete this;
            return 0;
        } else {
            return count;
        }
    }

    DesktopDropTarget::~DesktopDropTarget() {
        RevokeDragDrop(window_handle_);
        if (need_revoke_ole_initialize_) {
            OleUninitialize();
        }
    }

}  // namespace

void DesktopDropPluginRegisterWithRegistrar(
        FlutterDesktopPluginRegistrarRef registrar) {
    DesktopDropPlugin::RegisterWithRegistrar(
            flutter::PluginRegistrarManager::GetInstance()
                    ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));

}
