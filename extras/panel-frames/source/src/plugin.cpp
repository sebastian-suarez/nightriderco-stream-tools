#include "obs-api.hpp"
#include "panel-frames.hpp"
#include "runtime.hpp"
#include <QApplication>
#include <QDebug>
#include <QThread>

#define NRC_EXPORT extern "C" __attribute__((visibility("default")))
static QPointer<PanelFrames> controller;
static bool frontendAlive = false;

static void frontendEvent(obs_frontend_event event, void *)
{
    if (event == OBS_FRONTEND_EVENT_EXIT) {
        frontendAlive = false;
        delete controller.data();
        return;
    }
    switch (event) {
    case OBS_FRONTEND_EVENT_FINISHED_LOADING:
    case OBS_FRONTEND_EVENT_STUDIO_MODE_ENABLED:
    case OBS_FRONTEND_EVENT_STUDIO_MODE_DISABLED:
    case OBS_FRONTEND_EVENT_THEME_CHANGED:
        if (controller)
            QMetaObject::invokeMethod(controller, [] { if (controller) controller->refresh(); }, Qt::QueuedConnection);
        break;
    default: break;
    }
}

NRC_EXPORT void obs_module_set_pointer(void *) {}
NRC_EXPORT uint32_t obs_module_ver(void) { return nrcObsApiVersion; }
NRC_EXPORT const char *obs_module_name(void) { return "NIGHTRIDERCO Panel Frames"; }
NRC_EXPORT const char *obs_module_description(void) { return "Matching rounded Preview and Program frames for the NIGHTRIDERCO theme."; }
NRC_EXPORT const char *obs_module_author(void) { return "NIGHTRIDERCO"; }

NRC_EXPORT bool obs_module_load(void)
{
    if (!supportedRuntime(obs_get_version_string(), qVersion())) {
        qWarning("NIGHTRIDERCO Panel Frames: requires OBS 32.2.2 / Qt 6.11.1; extension disabled.");
        return false;
    }
    auto *main = static_cast<QWidget *>(obs_frontend_get_main_window());
    if (!qApp || !main || QThread::currentThread() != main->thread()) return false;
    controller = new PanelFrames(main);
    frontendAlive = true;
    obs_frontend_add_event_callback(frontendEvent, nullptr);
    return true;
}

NRC_EXPORT void obs_module_unload(void)
{
    if (frontendAlive) obs_frontend_remove_event_callback(frontendEvent, nullptr);
    frontendAlive = false;
    delete controller.data();
}
