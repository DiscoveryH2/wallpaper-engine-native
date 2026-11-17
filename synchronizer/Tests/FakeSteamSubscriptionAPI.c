#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Test-only Steam flat-API double. It exports the narrow ABI exercised by the
// subscription helper and never contacts Steam or writes account state.

enum { kCallbackAPICallCompleted = 703, kCallbackShutdownRequested = 704 };
enum { kSubscribeResult = 1313, kUnsubscribeResult = 1315 };

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

_Static_assert(offsetof(CallbackMessage, m_iCallback) == 4, "ManualDispatch callback id ABI");
_Static_assert(offsetof(CallbackMessage, m_pubParam) == 8, "ManualDispatch callback payload ABI");
_Static_assert(offsetof(CallbackMessage, m_cubParam) == 16, "ManualDispatch callback size ABI");
_Static_assert(sizeof(CallCompleted) == 16, "SteamAPICallCompleted_t ABI");

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
static int g_operation; // 1 subscribe, 2 unsubscribe
static int g_steam_id_reads;
static uint64_t g_item;
static uint64_t g_call;
static uint64_t g_query_handle;
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
    g_steam_id_reads = 0;
    g_item = UINT64_C(123456789);
    g_call = 0;
    g_query_handle = 0;
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
    // Construction reads the ID once, then its initial requireOnline reads it
    // again. This scenario flips only on the first validateSession inside
    // changeSubscription, proving that no SubscribeItem/UnsubscribeItem call
    // is needed for a stale constructor identity to become unsafe.
    return mode("account-b") || (mode("account-changed-before-start") && g_steam_id_reads >= 3)
        || (g_action_started && mode("account-changed-after-start"))
        ? UINT64_C(76561198000000002) : UINT64_C(76561198000000001);
}

uint32_t SteamAPI_ISteamUtils_GetAppID(void *self) { (void)self; return 431960; }
bool SteamAPI_ISteamApps_BIsSubscribedApp(void *self, uint32_t app) { (void)self; return app == 431960; }

void SteamAPI_ManualDispatch_Init(void) {}
int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
void SteamAPI_ManualDispatch_RunFrame(int32_t pipe) { (void)pipe; }

static uint64_t begin_change(uint64_t item, int operation) {
    g_action_started = 1;
    g_operation = operation;
    g_item = item;
    if (mode("request-rejected")) return 0;
    g_call = operation == 1 ? UINT64_C(0xA001) : UINT64_C(0xA002);
    g_completed.m_hAsyncCall = g_call;
    g_completed.m_iCallback = mode("wrong-callback") ? (operation == 1 ? kUnsubscribeResult : kSubscribeResult) : (operation == 1 ? kSubscribeResult : kUnsubscribeResult);
    g_completed.m_cubParam = 12;
    return g_call;
}

uint64_t SteamAPI_ISteamUGC_SubscribeItem(void *self, uint64_t item) { (void)self; return begin_change(item, 1); }
uint64_t SteamAPI_ISteamUGC_UnsubscribeItem(void *self, uint64_t item) { (void)self; return begin_change(item, 2); }

uint64_t SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(void *self, uint64_t *items, uint32_t count) {
    (void)self;
    if (items == NULL || count != 1 || items[0] == 0) return UINT64_MAX;
    g_item = items[0];
    g_query_handle = UINT64_C(0xD001);
    return g_query_handle;
}

bool SteamAPI_ISteamUGC_SetAllowCachedResponse(void *self, uint64_t handle, uint32_t max_age) {
    (void)self;
    return (handle == UINT64_C(0xD001) || handle == UINT64_C(0xC001) || handle == UINT64_C(0xC002)) && max_age == 0;
}

uint64_t SteamAPI_ISteamUGC_SendQueryUGCRequest(void *self, uint64_t handle) {
    (void)self;
    if (handle != UINT64_C(0xD001) && handle != UINT64_C(0xC001) && handle != UINT64_C(0xC002)) return 0;
    g_action_started = 1;
    g_operation = 3; // query
    g_query_handle = handle;
    g_event_delivered = 0;
    g_call = UINT64_C(0xB001);
    g_completed.m_hAsyncCall = g_call;
    g_completed.m_iCallback = 3401; // SteamUGCQueryCompleted_t
    g_completed.m_cubParam = 21;
    return g_call;
}

bool SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(void *self, uint64_t handle) { (void)self; return handle == UINT64_C(0xD001) || handle == UINT64_C(0xC001) || handle == UINT64_C(0xC002); }

uint64_t SteamAPI_ISteamUGC_CreateQueryUserUGCRequest(void *self, uint32_t account, int32_t list, int32_t matching, int32_t sort, uint32_t creator, uint32_t consumer, uint32_t page) {
    (void)self; (void)account; (void)matching; (void)sort; (void)creator; (void)consumer;
    if (page != 1 || (list != 5 && list != 6)) return UINT64_MAX;
    g_query_handle = list == 6 ? UINT64_C(0xC001) : UINT64_C(0xC002);
    return g_query_handle;
}

bool SteamAPI_ISteamUGC_GetQueryUGCResult(void *self, uint64_t handle, uint32_t index, void *out) {
    (void)self;
    if ((handle != UINT64_C(0xD001) && handle != UINT64_C(0xC001) && handle != UINT64_C(0xC002)) || index != 0 || out == NULL) return false;
    memset(out, 0, 8192);
    int32_t result = 1;
    uint32_t app = 431960;
    uint32_t updated = 1;
    memcpy((unsigned char *)out, &g_item, sizeof(g_item));
    memcpy((unsigned char *)out + 8, &result, sizeof(result));
    memcpy((unsigned char *)out + 20, &app, sizeof(app));
    memcpy((unsigned char *)out + 8168, &updated, sizeof(updated));
    return true;
}

uint32_t SteamAPI_ISteamUGC_GetItemState(void *self, uint64_t item) { (void)self; return item == g_item ? 4 : 0; }
uint32_t SteamAPI_ISteamUGC_GetNumSubscribedItems(void *self, bool include_disabled) { (void)self; (void)include_disabled; return 1; }
uint32_t SteamAPI_ISteamUGC_GetSubscribedItems(void *self, uint64_t *items, uint32_t maximum, bool include_disabled) {
    (void)self; (void)include_disabled;
    if (items == NULL || maximum < 1) return 0;
    items[0] = g_item;
    return 1;
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
    // Deliberately fail if FreeLastCallback already happened. This turns the
    // SDK's required ordering into an observable regression test.
    if (!g_callback_outstanding) return false;
    if (io_failure != NULL) *io_failure = mode("transport-failed");
    if (call != g_call || expected != g_completed.m_iCallback || mode("transport-failed")) return call == g_call;
    if (expected == 3401) {
        if (size != 21) return false;
        uint64_t handle = g_query_handle;
        int32_t result = 1;
        uint32_t returned = 1, total = 1;
        uint8_t cached = 0;
        memcpy((unsigned char *)out, &handle, sizeof(handle));
        memcpy((unsigned char *)out + 8, &result, sizeof(result));
        memcpy((unsigned char *)out + 12, &returned, sizeof(returned));
        memcpy((unsigned char *)out + 16, &total, sizeof(total));
        memcpy((unsigned char *)out + 20, &cached, sizeof(cached));
        return true;
    }
    if (size != 12) return false;
    int32_t result = mode("result-failed") ? 8 : 1; // k_EResultInvalidParam / OK
    uint64_t item = mode("wrong-item") ? g_item + 1 : g_item;
    memcpy((unsigned char *)out, &result, sizeof(result));
    memcpy((unsigned char *)out + 4, &item, sizeof(item));
    return true;
}

// Assertions use these only to prove that the test double, not real Steam,
// received the requested mutation intent.
uint64_t FakeSteamLastItem(void) { return g_item; }
int FakeSteamLastOperation(void) { return g_operation; }
int FakeSteamCallbacksBalanced(void) { return !g_callback_lifecycle_invalid && !g_callback_outstanding && g_next_count == g_free_count; }
