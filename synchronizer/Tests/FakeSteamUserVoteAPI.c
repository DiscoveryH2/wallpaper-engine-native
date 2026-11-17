#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Test-only ISteamUGC v021 flat-API double for GetUserItemVote and
// SetUserItemVote. It never discovers Steam, opens a socket, or reads a user
// directory. Every behavior is selected by FAKE_STEAM_VOTE_SCENARIO.

enum { kCallbackAPICallCompleted = 703, kCallbackShutdownRequested = 704 };
enum { kSetUserItemVoteResult = 3408, kGetUserItemVoteResult = 3409 };

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
    uint8_t m_bVoteUp;
    uint8_t m_padding[3];
} SetUserItemVoteResult;

typedef struct {
    uint64_t m_nPublishedFileId;
    int32_t m_eResult;
    uint8_t m_bVotedUp;
    uint8_t m_bVotedDown;
    uint8_t m_bVoteSkipped;
    uint8_t m_padding;
} GetUserItemVoteResult;
#pragma pack(pop)

_Static_assert(offsetof(CallbackMessage, m_iCallback) == 4, "ManualDispatch callback id ABI");
_Static_assert(offsetof(CallbackMessage, m_pubParam) == 8, "ManualDispatch callback payload ABI");
_Static_assert(offsetof(CallbackMessage, m_cubParam) == 16, "ManualDispatch callback size ABI");
_Static_assert(sizeof(CallCompleted) == 16, "SteamAPICallCompleted_t ABI");
_Static_assert(offsetof(SetUserItemVoteResult, m_nPublishedFileId) == 0, "3408 item offset");
_Static_assert(offsetof(SetUserItemVoteResult, m_eResult) == 8, "3408 result offset");
_Static_assert(offsetof(SetUserItemVoteResult, m_bVoteUp) == 12, "3408 direction offset");
_Static_assert(sizeof(SetUserItemVoteResult) == 16, "3408 macOS pack(4) ABI");
_Static_assert(offsetof(GetUserItemVoteResult, m_nPublishedFileId) == 0, "3409 item offset");
_Static_assert(offsetof(GetUserItemVoteResult, m_eResult) == 8, "3409 result offset");
_Static_assert(offsetof(GetUserItemVoteResult, m_bVotedUp) == 12, "3409 up offset");
_Static_assert(offsetof(GetUserItemVoteResult, m_bVotedDown) == 13, "3409 down offset");
_Static_assert(offsetof(GetUserItemVoteResult, m_bVoteSkipped) == 14, "3409 skipped offset");
_Static_assert(sizeof(GetUserItemVoteResult) == 16, "3409 macOS pack(4) ABI");

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
static int g_request_kind; // 1 get, 2 set
static int g_get_count;
static int g_set_count;
static int g_last_vote_up; // -1 before SetUserItemVote
static int g_steam_id_reads;
static uint64_t g_item;
static uint64_t g_call;
static CallCompleted g_completed;

static bool mode(const char *value) {
    const char *current = getenv("FAKE_STEAM_VOTE_SCENARIO");
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
    g_request_kind = 0;
    g_get_count = 0;
    g_set_count = 0;
    g_last_vote_up = -1;
    g_steam_id_reads = 0;
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
    // Construction reads twice. The third identity read is the pre-FFI
    // validation performed by userVote/changeUserVote.
    return mode("account-b") || (mode("account-changed-before-start") && g_steam_id_reads >= 3)
        || (g_action_started && mode("account-changed-after-start"))
        ? UINT64_C(76561198000000002) : UINT64_C(76561198000000001);
}

uint32_t SteamAPI_ISteamUtils_GetAppID(void *self) { (void)self; return 431960; }
bool SteamAPI_ISteamApps_BIsSubscribedApp(void *self, uint32_t app) { (void)self; return app == 431960; }

void SteamAPI_ManualDispatch_Init(void) {}
int32_t SteamAPI_GetHSteamPipe(void) { return 1; }
void SteamAPI_ManualDispatch_RunFrame(int32_t pipe) { (void)pipe; }

static uint64_t begin_vote(int request_kind, uint64_t item, bool vote_up) {
    g_request_kind = request_kind;
    g_item = item;
    if (request_kind == 1) g_get_count += 1;
    else {
        g_set_count += 1;
        g_last_vote_up = vote_up ? 1 : 0;
    }
    if (item == 0 || mode("request-rejected")) return 0;
    g_action_started = 1;
    g_call = request_kind == 1 ? UINT64_C(0xD001) : UINT64_C(0xD002);
    g_completed.m_hAsyncCall = mode("wrong-handle") ? g_call + 1 : g_call;
    g_completed.m_iCallback = mode("wrong-callback")
        ? (request_kind == 1 ? kSetUserItemVoteResult : kGetUserItemVoteResult)
        : (request_kind == 1 ? kGetUserItemVoteResult : kSetUserItemVoteResult);
    g_completed.m_cubParam = mode("wrong-size") ? 12 : 16;
    return g_call;
}

uint64_t SteamAPI_ISteamUGC_GetUserItemVote(void *self, uint64_t item) {
    (void)self;
    return begin_vote(1, item, false);
}

uint64_t SteamAPI_ISteamUGC_SetUserItemVote(void *self, uint64_t item, bool vote_up) {
    (void)self;
    return begin_vote(2, item, vote_up);
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

static void set_get_flags(GetUserItemVoteResult *result) {
    // `none` is the valid 000 state; only non-bool or multiple flags are a
    // malformed GET receipt. This fake exposes each state independently.
    if (mode("get-up") || mode("ok")) result->m_bVotedUp = 1;
    else if (mode("get-down")) result->m_bVotedDown = 1;
    else if (mode("get-skipped")) result->m_bVoteSkipped = 1;
    else if (mode("get-none")) { /* valid all-false state */ }
    else if (mode("get-flags-multiple")) { result->m_bVotedUp = 1; result->m_bVotedDown = 1; }
    else if (mode("get-flag-malformed")) result->m_bVotedUp = 2;
    else result->m_bVotedUp = 1;
}

bool SteamAPI_ManualDispatch_GetAPICallResult(int32_t pipe, uint64_t call, void *out, int32_t size, int32_t expected, bool *io_failure) {
    (void)pipe;
    // The real SDK requires the API result to be read before release. The
    // fake turns an incorrect ordering into a failed test.
    if (!g_callback_outstanding) return false;
    if (io_failure != NULL) *io_failure = mode("transport-failed");
    if (call != g_call || expected != g_completed.m_iCallback || mode("transport-failed")) return call == g_call;
    if (size != 16) return false;
    if (expected == kGetUserItemVoteResult && g_request_kind == 1) {
        GetUserItemVoteResult result;
        memset(&result, 0, sizeof(result));
        result.m_nPublishedFileId = mode("wrong-item") ? g_item + 1 : g_item;
        result.m_eResult = mode("result-failed") ? 8 : 1;
        set_get_flags(&result);
        memcpy(out, &result, sizeof(result));
        return true;
    }
    if (expected == kSetUserItemVoteResult && g_request_kind == 2) {
        SetUserItemVoteResult result;
        memset(&result, 0, sizeof(result));
        result.m_nPublishedFileId = mode("wrong-item") ? g_item + 1 : g_item;
        result.m_eResult = mode("result-failed") ? 8 : 1;
        result.m_bVoteUp = mode("direction-malformed") ? 2
            : (uint8_t)(mode("wrong-direction") ? (g_last_vote_up != 1) : (g_last_vote_up == 1));
        memcpy(out, &result, sizeof(result));
        return true;
    }
    return false;
}

// Test inspection only. They prove the isolated fake, not an installed Steam
// client, received the expected ABI calls and manual-dispatch lifecycle.
int FakeSteamVoteGetCount(void) { return g_get_count; }
int FakeSteamVoteSetCount(void) { return g_set_count; }
int FakeSteamVoteLastDirectionUp(void) { return g_last_vote_up; }
uint64_t FakeSteamVoteLastItem(void) { return g_item; }
int FakeSteamVoteCallbacksBalanced(void) { return !g_callback_lifecycle_invalid && !g_callback_outstanding && g_next_count == g_free_count; }
