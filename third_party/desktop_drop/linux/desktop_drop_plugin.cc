#include "include/desktop_drop/desktop_drop_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>

#define DESKTOP_DROP_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), desktop_drop_plugin_get_type(), \
                              DesktopDropPlugin))

struct _DesktopDropPlugin {
  GObject parent_instance;
  // 115Lab patch: kept for attaching to views that appear after registration.
  FlMethodChannel *channel;
};

static gboolean isKDE = FALSE;
static gboolean ignoreNext = FALSE;

G_DEFINE_TYPE(DesktopDropPlugin, desktop_drop_plugin, g_object_get_type())

void on_drag_data_received(GtkWidget *widget, GdkDragContext *drag_context,
                           gint x, gint y, GtkSelectionData *sdata, guint info,
                           guint time, gpointer user_data) {
  auto *channel = static_cast<FlMethodChannel *>(user_data);
  const gchar *method_name = "performOperation_linux";

  // The portal target carries a one-time transfer key instead of URIs.
  // Send it through its own method so Dart knows what it received.
  g_autofree gchar *target_name = gdk_atom_name(gtk_selection_data_get_target(sdata));
  if (target_name != nullptr &&
      strcmp(target_name, "application/vnd.portal.filetransfer") == 0) {
    method_name = "performOperation_portal";
  }

  // Selection data is not guaranteed to be NUL-terminated.
  gint length = gtk_selection_data_get_length(sdata);
  if (length < 0) {
    return;
  }
  g_autofree gchar *payload = g_strndup(
      reinterpret_cast<const gchar *>(gtk_selection_data_get_data(sdata)), length);

  double point[] = {double(x), double(y)};
  g_autoptr(FlValue) args = fl_value_new_list();
  fl_value_append(args, fl_value_new_string(payload));
  fl_value_append(args, fl_value_new_float_list(point, 2));
  fl_method_channel_invoke_method(channel, method_name, args,
                                  nullptr, nullptr, nullptr);
}

void on_drag_motion(GtkWidget *widget, GdkDragContext *drag_context,
                    gint x, gint y, guint time, gpointer user_data) {
  if (ignoreNext) {
    ignoreNext = FALSE;
    return;
  }

  auto *channel = static_cast<FlMethodChannel *>(user_data);
  double point[] = {double(x), double(y)};
  g_autoptr(FlValue) args = fl_value_new_float_list(point, 2);
  fl_method_channel_invoke_method(channel, "updated", args,
                                  nullptr, nullptr, nullptr);
}

void on_drag_leave(GtkWidget *widget, GdkDragContext *drag_context, guint time, gpointer user_data) {
  auto *channel = static_cast<FlMethodChannel *>(user_data);
  fl_method_channel_invoke_method(channel, "exited", nullptr,
                                  nullptr, nullptr, nullptr);
}

// Called when a method call is received from Flutter.
static gboolean attach_to_view(DesktopDropPlugin *self, FlView *fl_view);

// 115Lab patch: the first FlView inside [widget], depth first.
static FlView *find_fl_view(GtkWidget *widget) {
  if (FL_IS_VIEW(widget)) return FL_VIEW(widget);
  if (!GTK_IS_CONTAINER(widget)) return nullptr;
  g_autoptr(GList) children = gtk_container_get_children(GTK_CONTAINER(widget));
  for (GList *child = children; child != nullptr; child = child->next) {
    FlView *view = find_fl_view(GTK_WIDGET(child->data));
    if (view != nullptr) return view;
  }
  return nullptr;
}

// 115Lab patch: `attachToWindow {handle: GtkWindow* as int}` — accept drops on
// that window's Flutter view. A multi-view engine creates its windows after
// plugin registration, when the registrar has no view to hand out.
static FlMethodResponse *attach_to_window(DesktopDropPlugin *self,
                                          FlValue *args) {
  FlValue *handle = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
      ? fl_value_lookup_string(args, "handle")
      : nullptr;
  if (handle == nullptr || fl_value_get_type(handle) != FL_VALUE_TYPE_INT) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(FALSE)));
  }
  gpointer target = GSIZE_TO_POINTER(fl_value_get_int(handle));
  // Only a live toplevel of this process: a stale handle must not be touched.
  g_autoptr(GList) toplevels = gtk_window_list_toplevels();
  gboolean attached = FALSE;
  for (GList *item = toplevels; item != nullptr; item = item->next) {
    if (item->data != target) continue;
    FlView *view = find_fl_view(GTK_WIDGET(item->data));
    attached = view != nullptr && attach_to_view(self, view);
    break;
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(attached)));
}

static void desktop_drop_plugin_handle_method_call(
    DesktopDropPlugin *self,
    FlMethodCall *method_call) {
  if (strcmp(fl_method_call_get_name(method_call), "attachToWindow") == 0) {
    g_autoptr(FlMethodResponse) response =
        attach_to_window(self, fl_method_call_get_args(method_call));
    fl_method_call_respond(method_call, response, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

static void desktop_drop_plugin_dispose(GObject *object) {
  G_OBJECT_CLASS(desktop_drop_plugin_parent_class)->dispose(object);
}

static void desktop_drop_plugin_class_init(DesktopDropPluginClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = desktop_drop_plugin_dispose;
}

static void desktop_drop_plugin_init(DesktopDropPlugin *self) {
  const char * desktopEnv = getenv("XDG_CURRENT_DESKTOP");
  if (desktopEnv) {
    const char * lowercaseDesktopEnv = g_ascii_strdown(desktopEnv, -1);

    if (strcmp(lowercaseDesktopEnv, "kde") == 0 || strcmp(lowercaseDesktopEnv, "plasma") == 0) {
        isKDE = TRUE;
    }
  }
}

static gboolean on_focus_in_event(GtkWidget *widget, GdkEventFocus *event, gpointer user_data) {
  if (isKDE) {
    ignoreNext = TRUE;
  }
  return FALSE;
}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data) {
  DesktopDropPlugin *plugin = DESKTOP_DROP_PLUGIN(user_data);
  desktop_drop_plugin_handle_method_call(plugin, method_call);
}

static gboolean attach_to_view(DesktopDropPlugin *self, FlView *fl_view) {
  // Attaching twice would deliver every drop twice.
  if (g_object_get_data(G_OBJECT(fl_view), "desktop-drop-attached") != nullptr) {
    return TRUE;
  }
  g_object_set_data(G_OBJECT(fl_view), "desktop-drop-attached", GINT_TO_POINTER(1));

  // Register portal file transfer target FIRST (highest priority)
  // then STRING, then URI targets
  static GtkTargetEntry entries[] = {
      {strdup("application/vnd.portal.filetransfer"), GTK_TARGET_OTHER_APP, 0},
      {strdup("STRING"), GTK_TARGET_OTHER_APP, 0}
  };
  gtk_drag_dest_set(GTK_WIDGET(fl_view), GTK_DEST_DEFAULT_ALL, entries, 2, GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(GTK_WIDGET(fl_view));

  g_signal_connect(fl_view, "drag-motion",
                   G_CALLBACK(on_drag_motion), self->channel);
  g_signal_connect(GTK_WIDGET(fl_view), "drag-data-received",
                   G_CALLBACK(on_drag_data_received), self->channel);
  g_signal_connect(GTK_WIDGET(fl_view), "drag-leave",
                   G_CALLBACK(on_drag_leave), self->channel);
  g_signal_connect(fl_view, "focus-in-event",
                   G_CALLBACK(on_focus_in_event), nullptr);
  return TRUE;
}

void desktop_drop_plugin_register_with_registrar(FlPluginRegistrar *registrar) {
  DesktopDropPlugin *plugin = DESKTOP_DROP_PLUGIN(
      g_object_new(desktop_drop_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Lives as long as the app, as upstream's did: the drag signals point at it.
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "desktop_drop",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  // 115Lab patch: a multi-view engine may have no view at registration; the
  // app attaches to its window later with `attachToWindow`.
  FlView *fl_view = fl_plugin_registrar_get_view(registrar);
  if (fl_view != nullptr) attach_to_view(plugin, fl_view);

  g_object_unref(plugin);
}
