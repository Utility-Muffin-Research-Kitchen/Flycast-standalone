/* Exact request URLs for a Leaf proxy session, built by the pinned rcheevos
   exactly the way rc_client_set_host() applies a host: image host cleared,
   then the API host set. Proves no doubled scheme and no unintended HTTPS
   for API, badge, game-image and user-picture requests, and that clearing
   the session host restores the real origins. */
#include "rc_api_request.h"
#include "rc_api_user.h"
#include "rc_api_runtime.h"

#include <stdio.h>
#include <string.h>

void rc_api_set_host(const char* hostname);
void rc_api_set_image_host(const char* hostname);

static int failures;

static void expect_url(const char* got, const char* want, const char* what) {
    if (!got || strcmp(got, want) != 0) {
        fprintf(stderr, "ra-route-urls: %s: got [%s], want [%s]\n", what, got ? got : "(null)", want);
        failures++;
    }
}

static void apply_host(const char* host) { /* rc_client_set_host(), minus logging */
    rc_api_set_image_host(NULL);
    rc_api_set_host(host);
}

static void check(const char* host, const char* api, const char* image) {
    char want[256];
    rc_api_request_t req;

    apply_host(host);

    rc_api_login_request_t login;
    memset(&login, 0, sizeof(login));
    login.username = "synthetic";
    login.api_token = "synthetic-token";
    if (rc_api_init_login_request(&req, &login) != RC_OK) { failures++; return; }
    snprintf(want, sizeof(want), "%s/dorequest.php", api);
    expect_url(req.url, want, "login");
    rc_api_destroy_request(&req);

    rc_api_fetch_image_request_t img;
    memset(&img, 0, sizeof(img));
    img.image_name = "12345";
    img.image_type = RC_IMAGE_TYPE_ACHIEVEMENT;
    if (rc_api_init_fetch_image_request(&req, &img) != RC_OK) { failures++; return; }
    snprintf(want, sizeof(want), "%s/Badge/12345.png", image);
    expect_url(req.url, want, "badge");
    rc_api_destroy_request(&req);

    img.image_type = RC_IMAGE_TYPE_ACHIEVEMENT_LOCKED;
    rc_api_init_fetch_image_request(&req, &img);
    snprintf(want, sizeof(want), "%s/Badge/12345_lock.png", image);
    expect_url(req.url, want, "locked badge");
    rc_api_destroy_request(&req);

    img.image_type = RC_IMAGE_TYPE_GAME;
    rc_api_init_fetch_image_request(&req, &img);
    snprintf(want, sizeof(want), "%s/Images/12345.png", image);
    expect_url(req.url, want, "game image");
    rc_api_destroy_request(&req);

    img.image_type = RC_IMAGE_TYPE_USER;
    img.image_name = "Synthetic";
    rc_api_init_fetch_image_request(&req, &img);
    snprintf(want, sizeof(want), "%s/UserPic/Synthetic.png", image);
    expect_url(req.url, want, "user picture");
    rc_api_destroy_request(&req);
}

int main(void) {
    /* The Leaf session host, as patch 0003 passes it. */
    check("http://127.0.0.1:8080", "http://127.0.0.1:8080", "http://127.0.0.1:8080");
    /* RetroArch's bare form resolves to the same URLs. */
    check("127.0.0.1:8080", "http://127.0.0.1:8080", "http://127.0.0.1:8080");
    /* Clearing the session host goes back to the real HTTPS origins. */
    check(NULL, "https://retroachievements.org", "https://media.retroachievements.org");
    if (failures) {
        fprintf(stderr, "ra-route-urls: %d FAILURE(S)\n", failures);
        return 1;
    }
    printf("ra-route-urls: session and direct request URLs ok\n");
    return 0;
}
