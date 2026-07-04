#include <furi.h>
#include <furi_hal.h>
#include <gui/gui.h>
#include <gui/view_port.h>
#include <input/input.h>
#include <rpc/rpc_app.h>
#include <storage/storage.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TAG "DolphinDeck"
#define DD_PROTOCOL "DD1"
#define DD_SETTINGS_DIR "/ext/apps_data/dolphin_deck_bridge"
#define DD_SETTINGS_PATH DD_SETTINGS_DIR "/settings.bin"
#define DD_EVENT_BUFFER 96
#define DD_ITEM_COUNT 9

typedef enum {
    DdTransportIPhone = 0,
    DdTransportESP32 = 1,
} DdTransport;

typedef enum {
    DdEventInput,
    DdEventRpcData,
    DdEventRpcExit,
} DdEventType;

typedef struct {
    DdEventType type;
    InputEvent input;
    char data[DD_EVENT_BUFFER];
} DdEvent;

typedef struct {
    Gui* gui;
    Storage* storage;
    ViewPort* viewport;
    FuriMessageQueue* queue;
    RpcAppSystem* rpc;
    DdTransport transport;
    bool running;
    uint8_t selection;
    uint8_t scroll;
    char status[DD_EVENT_BUFFER];
} DdApp;

static const char* const dd_labels[DD_ITEM_COUNT] = {
    "Find iPhone",
    "Notification",
    "Volume +",
    "Volume -",
    "Play / Pause",
    "Home (ESP32)",
    "App switch (ESP32)",
    "Lock iPhone",
    "Connection mode",
};

static const char* const dd_commands[DD_ITEM_COUNT] = {
    "FIND_PHONE",
    "NOTIFY",
    "VOLUME_UP",
    "VOLUME_DOWN",
    "PLAY_PAUSE",
    "HOME",
    "APP_SWITCHER",
    "LOCK_REQUEST",
    NULL,
};

static void dd_set_status(DdApp* app, const char* status) {
    strlcpy(app->status, status, sizeof(app->status));
}

static void dd_save_settings(DdApp* app) {
    storage_common_mkdir(app->storage, DD_SETTINGS_DIR);
    File* file = storage_file_alloc(app->storage);
    if(storage_file_open(file, DD_SETTINGS_PATH, FSAM_WRITE, FSOM_CREATE_ALWAYS)) {
        const uint8_t value = (uint8_t)app->transport;
        storage_file_write(file, &value, sizeof(value));
    }
    storage_file_close(file);
    storage_file_free(file);
}

static void dd_load_settings(DdApp* app) {
    File* file = storage_file_alloc(app->storage);
    uint8_t value = 0;
    if(storage_file_open(file, DD_SETTINGS_PATH, FSAM_READ, FSOM_OPEN_EXISTING) &&
       storage_file_read(file, &value, sizeof(value)) == sizeof(value) &&
       value <= DdTransportESP32) {
        app->transport = (DdTransport)value;
    }
    storage_file_close(file);
    storage_file_free(file);
}

static bool dd_uart_send(const char* command) {
    FuriHalSerialHandle* serial =
        furi_hal_serial_control_acquire(FuriHalSerialIdUsart);
    if(!serial) return false;

    char line[64];
    snprintf(line, sizeof(line), DD_PROTOCOL "|HID|%s\n", command);
    furi_hal_serial_init(serial, 115200);
    furi_hal_serial_tx(serial, (const uint8_t*)line, strlen(line));
    furi_hal_serial_tx_wait_complete(serial);
    furi_hal_serial_deinit(serial);
    furi_hal_serial_control_release(serial);
    return true;
}

static void dd_send_command(DdApp* app, const char* command) {
    if(app->transport == DdTransportESP32) {
        dd_set_status(
            app,
            dd_uart_send(command) ? "Sent to ESP32" : "GPIO UART is busy");
        return;
    }

    if(!app->rpc) {
        dd_set_status(app, "Start from iPhone app");
        return;
    }

    char message[64];
    snprintf(message, sizeof(message), DD_PROTOCOL "|EVENT|%s", command);
    rpc_system_app_exchange_data(app->rpc, (const uint8_t*)message, strlen(message));
    dd_set_status(app, "Sent to iPhone");
}

static void dd_rpc_callback(const RpcAppSystemEvent* event, void* context) {
    DdApp* app = context;
    DdEvent queued = {.type = DdEventRpcData};

    switch(event->type) {
    case RpcAppEventTypeDataExchange: {
        const size_t count =
            event->data.bytes.size < sizeof(queued.data) - 1 ?
                event->data.bytes.size :
                sizeof(queued.data) - 1;
        memcpy(queued.data, event->data.bytes.ptr, count);
        queued.data[count] = '\0';
        furi_message_queue_put(app->queue, &queued, 0);
        rpc_system_app_confirm(app->rpc, true);
        break;
    }
    case RpcAppEventTypeAppExit:
        queued.type = DdEventRpcExit;
        furi_message_queue_put(app->queue, &queued, 0);
        rpc_system_app_confirm(app->rpc, true);
        break;
    case RpcAppEventTypeSessionClose:
        app->rpc = NULL;
        queued.type = DdEventRpcData;
        strlcpy(queued.data, "DD1|STATUS|IPHONE_DISCONNECTED", sizeof(queued.data));
        furi_message_queue_put(app->queue, &queued, 0);
        break;
    default:
        rpc_system_app_confirm(app->rpc, true);
        break;
    }
}

static void dd_input_callback(InputEvent* input, void* context) {
    DdApp* app = context;
    DdEvent event = {
        .type = DdEventInput,
        .input = *input,
    };
    furi_message_queue_put(app->queue, &event, 0);
}

static void dd_draw_callback(Canvas* canvas, void* context) {
    DdApp* app = context;
    canvas_clear(canvas);
    canvas_set_font(canvas, FontPrimary);
    canvas_draw_str(canvas, 2, 10, "Dolphin Deck");
    canvas_set_font(canvas, FontSecondary);
    canvas_draw_str_aligned(
        canvas,
        126,
        9,
        AlignRight,
        AlignBottom,
        app->transport == DdTransportIPhone ? (app->rpc ? "iPhone ON" : "iPhone --") :
                                             "ESP32 UART");
    canvas_draw_line(canvas, 0, 13, 127, 13);

    for(uint8_t row = 0; row < 4; row++) {
        const uint8_t index = app->scroll + row;
        if(index >= DD_ITEM_COUNT) break;
        const uint8_t y = 15 + row * 10;
        if(index == app->selection) {
            canvas_set_color(canvas, ColorBlack);
            canvas_draw_box(canvas, 0, y, 128, 10);
            canvas_set_color(canvas, ColorWhite);
        }
        canvas_draw_str(canvas, 3, y + 8, dd_labels[index]);
        if(index == DD_ITEM_COUNT - 1) {
            canvas_draw_str_aligned(
                canvas,
                124,
                y + 8,
                AlignRight,
                AlignBottom,
                app->transport == DdTransportIPhone ? "iPhone" : "ESP32");
        }
        canvas_set_color(canvas, ColorBlack);
    }

    canvas_draw_line(canvas, 0, 55, 127, 55);
    canvas_set_font(canvas, FontSecondary);
    canvas_draw_str_aligned(canvas, 64, 63, AlignCenter, AlignBottom, app->status);
}

static void dd_handle_rpc_data(DdApp* app, const char* message) {
    if(strcmp(message, "DD1|CONFIG|TRANSPORT|IPHONE") == 0) {
        app->transport = DdTransportIPhone;
        dd_save_settings(app);
        dd_set_status(app, "Mode: iPhone RPC");
        return;
    }
    if(strcmp(message, "DD1|CONFIG|TRANSPORT|ESP32") == 0) {
        app->transport = DdTransportESP32;
        dd_save_settings(app);
        dd_set_status(app, "Mode: ESP32 GPIO");
        return;
    }
    if(strncmp(message, "DD1|HELLO|", 10) == 0) {
        dd_set_status(app, "iPhone connected");
        const char* reply = "DD1|HELLO|FLIPPER_1.1.0";
        if(app->rpc) {
            rpc_system_app_exchange_data(
                app->rpc,
                (const uint8_t*)reply,
                strlen(reply));
        }
        return;
    }
    const char* payload = strrchr(message, '|');
    dd_set_status(app, payload && payload[1] ? payload + 1 : message);
}

static void dd_handle_input(DdApp* app, const InputEvent* input) {
    const bool navigate =
        input->type == InputTypeShort || input->type == InputTypeRepeat;
    if(navigate && input->key == InputKeyUp) {
        if(app->selection > 0) app->selection--;
    } else if(navigate && input->key == InputKeyDown) {
        if(app->selection + 1 < DD_ITEM_COUNT) app->selection++;
    } else if(input->type == InputTypeShort && input->key == InputKeyBack) {
        app->running = false;
    } else if(input->type == InputTypeShort && input->key == InputKeyOk) {
        if(app->selection == DD_ITEM_COUNT - 1) {
            app->transport =
                app->transport == DdTransportIPhone ? DdTransportESP32 :
                                                      DdTransportIPhone;
            dd_save_settings(app);
            dd_set_status(
                app,
                app->transport == DdTransportIPhone ? "Mode: iPhone RPC" :
                                                     "Mode: ESP32 GPIO");
        } else {
            dd_send_command(app, dd_commands[app->selection]);
        }
    }

    if(app->selection < app->scroll) app->scroll = app->selection;
    if(app->selection >= app->scroll + 4) app->scroll = app->selection - 3;
}

int32_t dolphin_deck_bridge_app(void* args) {
    DdApp* app = malloc(sizeof(DdApp));
    furi_check(app);
    memset(app, 0, sizeof(DdApp));
    app->running = true;
    app->transport = DdTransportIPhone;
    strlcpy(app->status, "Ready", sizeof(app->status));

    app->gui = furi_record_open(RECORD_GUI);
    app->storage = furi_record_open(RECORD_STORAGE);
    app->queue = furi_message_queue_alloc(8, sizeof(DdEvent));
    app->viewport = view_port_alloc();
    dd_load_settings(app);

    unsigned long rpc_context = 0;
    if(args && sscanf(args, "RPC %lX", &rpc_context) == 1) {
        app->rpc = (RpcAppSystem*)rpc_context;
        rpc_system_app_set_callback(app->rpc, dd_rpc_callback, app);
        rpc_system_app_send_started(app->rpc);
        dd_set_status(app, "iPhone connected");
    }

    view_port_draw_callback_set(app->viewport, dd_draw_callback, app);
    view_port_input_callback_set(app->viewport, dd_input_callback, app);
    gui_add_view_port(app->gui, app->viewport, GuiLayerFullscreen);

    while(app->running) {
        DdEvent event;
        if(furi_message_queue_get(app->queue, &event, FuriWaitForever) != FuriStatusOk) {
            continue;
        }
        if(event.type == DdEventInput) {
            dd_handle_input(app, &event.input);
        } else if(event.type == DdEventRpcData) {
            dd_handle_rpc_data(app, event.data);
        } else if(event.type == DdEventRpcExit) {
            app->running = false;
        }
        view_port_update(app->viewport);
    }

    if(app->rpc) rpc_system_app_send_exited(app->rpc);
    gui_remove_view_port(app->gui, app->viewport);
    view_port_free(app->viewport);
    furi_message_queue_free(app->queue);
    furi_record_close(RECORD_STORAGE);
    furi_record_close(RECORD_GUI);
    free(app);
    return 0;
}
