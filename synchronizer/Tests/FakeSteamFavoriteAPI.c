#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Test-only ISteamUGC v021 flat-API double for Add/RemoveItemToFavorites.
// It has no Steam installation, network, account, or filesystem dependency.

enum { kCallbackAPICallCompleted = 703, kCallbackShutdownRequested = 704 };
enum { kFavoriteResult = 3407 };

typedef struct {
    int32_t m_hSteamUser;
    int32_t m_iCallback;
    void *m_pubParam;
    int32_t m_cubParam;
} CallbackMessage;

typedef struct {
    uint64_t m_hAsyncCall;
    int32_t m_iCallback;
    uint32_t m_cubParam;
} CallCompleted;

#pragma pack(push, 4)
typedef struct {
    uint64_t m_nPublishedFileId;
    int32_t m_eResult;
    uint8_t m_bWasAddRequest;
    uint8_t m_padding[3];
} UserFavoriteItemsListChanged;
#pragma pack(pop)

_Static_assert(offsetof(CallbackMessage, m_iCallback) == 4, "ManualDispatch callback id ABI");
_Static_assert(offsetof(CallbackMessage, m_pubParam) == 8, "ManualDispatch callback payload ABI");
_Static_assert(offsetof(CallbackMessage, m_cubParam) == 16, "ManualDispatch callback size ABI");
_Static_assert(sizeof(CallCompleted) == 16, "SteamAPICallCompleted_t ABI");
_Static_assert(offsetof(UserFavoriteItemsListChanged, m_nPublishedFileId) == 0, "3407 item offset");
_Static_assert(offsetof(UserFavoriteItemsListChanged, m_eResult) == 8, "3407 result offset");
_Static_assert(offsetof(UserFavoriteItemsListChanged, m_bWasAddRequest) == 12, "3407 direction offset");
_Static_assert(sizeof(UserFavoriteItemsListChanged) == 16, "3407 macOS pack(4) ABI");

static int g_user;
static int g_ugc;
static int g_utils;
static int g_apps;
static int g_action_started;
static int g_event_delivered;
static int g_callback_outstanding;
static int g_next_count;
static int g_free_count;
static int g_callback_lifecycle_invalid;
static int g_operation; // 1 add, 2 remove
static int g_mutation_count;
static int g_steam_id_reads;
static uint32_t g_app_id;
static uint64_t g_item;
static uint64_t g_call;
static CallCompleted g_completed;

static bool mode(const char *value) {
    const char *current = getenv("FAKE_STEAM_SCENARIO");
    return current != NULL && strcmp(current, value) == 0;
}

bool SteamAPI_IsSteamRunning(void) { return true; }

int32_t SteamAPI_InitFlat(char *error) {
    g_action_started = 0;
    g_event_delivered = 0;
    g_callback_outstanding = 0;
    g_next_count = 0;
    g_free_count = 0;
    g_callback_lifecycle_invalid = 0;
    g_operation = 0;
    g_mutation_count = 0;
    g_steam_id_reads = 0;
    g_app_id = 0;
    g_item = UINT64_C(123456789);
    g_call = 0;
    memset(&g_completed, 0, sizeof(g_completed));
    if (error != NULL) error[0] = '\0';
    return 0;
}

void SteamAPI_Shutdown(void) {}
void *SteamAPI_SteamUser_v023(void) { return &g_user; }
void *SteamAPI_SteamUGC_v021(void) { return &g_ugc; }
void *SteamAPI_SteamUtils_v011(void) { return &g_utils; }
void *SteamAPI_SteamApps_v009(void) { return &g_apps; }

bool SteamAPI_ISteamUser_BLoggedOn(void *self) {
    (void)self;
    return !mode("offline-preflight") && !(g_action_started && mode("offline-after-start"));
}

uint64_t SteamAPI_ISteamUser_GetSteamID(void *self) {
    (void)self;
    g_steam_id_reads += 1;
    // Construction reads twice. The third identity read belongs to the
    // pre-FFI validateSession inside changeFavorite.
    return mode("account-b") || (mode("account-changed-before-start") && g_steam_id_reads >= 3)
        || (g_action_started && mode("account-changed-after-start"))
        ? UINT64_C(76561198000000002) : UINT64_C(76561198000000001);
}

uint32_t SteamAPI_ISteamUtils_GetAppID(void *self) { (void)self; return 431960; }
bool SteamAPI_ISteamApps_BIsSubscribedApp(void *self, uint32_t app) { (void)self; return app == 431960; }

void SteamAPI_ManualDispatch_Init(void) {}
int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
void SteamAPI_ManualDispatch_RunFrame(int32_t pipe) { (void)pipe; }

static uint64_t begin_favorite(uint32_t app_id, uint64_t item, int operation) {
    g_app_id = app_id;
    g_item = item;
    g_operation = operation;
    g_mutation_count += 1;
    if (app_id != 431960 || item == 0 || mode("request-rejected")) return 0;
    g_action_started = 1;
    g_call = operation == 1 ? UINT64_C(0xF001) : UINT64_C(0xF002);
    g_completed.m_hAsyncCall = mode("wrong-handle") ? g_call + 1 : g_call;
    g_completed.m_iCallback = mode("wrong-callback") ? 3408 : kFavoriteResult;
    g_completed.m_cubParam = mode("wrong-size") ? 12 : 16;
    return g_call;
}

uint64_t SteamAPI_ISteamUGC_AddItemToFavorites(void *self, uint32_t app_id, uint64_t item) {
    (void)self;
    return begin_favorite(app_id, item, 1);
}

uint64_t SteamAPI_ISteamUGC_RemoveItemFromFavorites(void *self, uint32_t app_id, uint64_t item) {
    (void)self;
    return begin_favorite(app_id, item, 2);
}

bool SteamAPI_ManualDispatch_GetNextCallback(int32_t pipe, void *out) {
    (void)pipe;
    if (g_callback_outstanding) { g_callback_lifecycle_invalid = 1; return false; }
    if (g_call == 0 || g_event_delivered || mode("no-callback")) return false;
    CallbackMessage *message = (CallbackMessage *)out;
    memset(message, 0, sizeof(*message));
    g_event_delivered = 1;
    g_callback_outstanding = 1;
    g_next_count += 1;
    if (mode("shutdown-after-start")) {
        message->m_iCallback = kCallbackShutdownRequested;
        return true;
    }
    message->m_iCallback = kCallbackAPICallCompleted;
    message->m_pubParam = &g_completed;
    message->m_cubParam = (int32_t)sizeof(g_completed);
    return true;
}

void SteamAPI_ManualDispatch_FreeLastCallback(int32_t pipe) {
    (void)pipe;
    if (!g_callback_outstanding) { g_callback_lifecycle_invalid = 1; return; }
    g_callback_outstanding = 0;
    g_free_count += 1;
}

bool SteamAPI_ManualDispatch_GetAPICallResult(int32_t pipe, uint64_t call, void *out, int32_t size, int32_t expected, bool *io_failure) {
    (void)pipe;
    // Make the required read-before-FreeLastCallback ordering observable.
    if (!g_callback_outstanding) return false;
    if (io_failure != NULL) *io_failure = mode("transport-failed");
    if (call != g_call || expected != g_completed.m_iCallback || mode("transport-failed")) return call == g_call;
    if (expected != kFavoriteResult || size != 16) return false;
    UserFavoriteItemsListChanged changed;
    memset(&changed, 0, sizeof(changed));
    changed.m_nPublishedFileId = mode("wrong-item") ? g_item + 1 : g_item;
    changed.m_eResult = mode("result-failed") ? 8 : 1; // k_EResultInvalidParam / OK
    changed.m_bWasAddRequest = mode("direction-malformed") ? 2
        : (uint8_t)(mode("wrong-direction") ? (g_operation != 1) : (g_operation == 1));
    memcpy(out, &changed, sizeof(changed));
    return true;
}

// Test inspection only. These prove that the fake dylib, not Steam, received
// exactly one requested write attempt and correct ABI arguments.
int FakeSteamLastOperation(void) { return g_operation; }
int FakeSteamMutationCount(void) { return g_mutation_count; }
uint32_t FakeSteamLastAppID(void) { return g_app_id; }
int FakeSteamCallbacksBalanced(void) { return !g_callback_lifecycle_invalid && !g_callback_outstanding && g_next_count == g_free_count; }
