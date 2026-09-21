// Host test for the half of the account bridge that the shared contract
// fixtures cannot reach: the durable marker, and the transition the marker
// and the snapshot select together.
//
// The fixtures prove which handoffs are well formed. These cases prove what
// the emulator then DOES with one -- including what it refuses to do when a
// write fails, when the marker is damaged, and when the handoff disappears
// while managed state is still on the card.
#include "achievements/ra_account.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using namespace achievements::ra_account;

static int failures = 0;
static int checks = 0;
static std::string tempRoot;

static void check(bool condition, const std::string& what)
{
	checks++;
	if (condition) {
		printf("ok   %s\n", what.c_str());
	}
	else {
		printf("FAIL %s\n", what.c_str());
		failures++;
	}
}

static std::string path(const std::string& name) {
	return tempRoot + "/" + name;
}

static void writeFile(const std::string& file, const std::string& content)
{
	FILE *f = fopen(file.c_str(), "wb");
	if (f == nullptr) {
		fprintf(stderr, "cannot write %s\n", file.c_str());
		exit(2);
	}
	fwrite(content.data(), 1, content.size(), f);
	fclose(f);
}

static std::string readFile(const std::string& file)
{
	FILE *f = fopen(file.c_str(), "rb");
	if (f == nullptr)
		return {};
	std::string content;
	char buffer[512];
	size_t read;
	while ((read = fread(buffer, 1, sizeof(buffer), f)) > 0)
		content.append(buffer, read);
	fclose(f);
	return content;
}

static Snapshot configuredSnapshot(const std::string& user, const std::string& password,
		long long revision)
{
	std::map<std::string, std::string> env;
	env["UMRK_RA_ACCOUNT_VERSION"] = "1";
	env["UMRK_RA_ACCOUNT_STATE"] = "configured";
	env["UMRK_RA_ACCOUNT_USERNAME"] = user;
	env["UMRK_RA_ACCOUNT_PASSWORD"] = password;
	env["UMRK_RA_ACCOUNT_REVISION"] = std::to_string(revision);
	return classify(env);
}

static Snapshot simpleSnapshot(const std::string& state, long long revision)
{
	std::map<std::string, std::string> env;
	env["UMRK_RA_ACCOUNT_VERSION"] = "1";
	env["UMRK_RA_ACCOUNT_STATE"] = state;
	if (revision > 0)
		env["UMRK_RA_ACCOUNT_REVISION"] = std::to_string(revision);
	return classify(env);
}

// ---------------------------------------------------------------------------

static void testMarkerRoundTrip()
{
	const std::string file = path("marker-roundtrip");
	Marker marker;
	marker.transition = Transition::Accepted;
	marker.revision = 7;
	// Spaces and punctuation are valid account data and must survive.
	marker.account = "o'hara \"junior\" jr";
	check(writeMarker(file, marker), "marker: write an accepted marker");

	Marker read;
	check(readMarker(file, read) == MarkerStatus::Ok, "marker: read it back");
	check(read.transition == Transition::Accepted && read.revision == 7
			&& read.account == marker.account,
			"marker: round trip keeps transition, revision and account");
	check(readFile(file).find("password") == std::string::npos,
			"marker: contains no password field");

	Marker signedOut;
	signedOut.transition = Transition::SignedOut;
	signedOut.revision = 0;
	check(writeMarker(file, signedOut), "marker: a sign-out with no revision is writable");
	check(readMarker(file, read) == MarkerStatus::Ok && read.revision == 0
			&& read.transition == Transition::SignedOut,
			"marker: revision 0 is only valid for a sign-out");

	check(readMarker(path("marker-absent"), read) == MarkerStatus::Absent,
			"marker: a missing file is absent, not malformed");
}

static void testMarkerRejectsDamage()
{
	Marker read;
	struct Case {
		const char *name;
		const char *content;
	};
	const Case cases[] = {
		{ "empty file", "" },
		{ "wrong header", "umrk-ra-account 2\nstate accepted\nrevision 1\naccount a\n" },
		{ "missing state", "umrk-ra-account 1\nrevision 1\naccount a\n" },
		{ "missing revision", "umrk-ra-account 1\nstate accepted\naccount a\n" },
		{ "missing account", "umrk-ra-account 1\nstate accepted\nrevision 1\n" },
		{ "unknown transition", "umrk-ra-account 1\nstate half\nrevision 1\naccount a\n" },
		{ "unknown key", "umrk-ra-account 1\nstate accepted\nrevision 1\naccount a\ntoken x\n" },
		{ "non-numeric revision", "umrk-ra-account 1\nstate accepted\nrevision one\naccount a\n" },
		{ "negative revision", "umrk-ra-account 1\nstate accepted\nrevision -1\naccount a\n" },
		{ "revision past the ceiling", "umrk-ra-account 1\nstate accepted\nrevision 4611686018427387905\naccount a\n" },
		{ "duplicate key", "umrk-ra-account 1\nstate accepted\nstate pending\nrevision 1\naccount a\n" },
		{ "accepted without a revision", "umrk-ra-account 1\nstate accepted\nrevision 0\naccount a\n" },
		{ "truncated mid-write", "umrk-ra-account 1\nstate accep" },
	};
	for (const Case& testCase : cases)
	{
		const std::string file = path("marker-damaged");
		writeFile(file, testCase.content);
		check(readMarker(file, read) == MarkerStatus::Malformed,
				std::string("marker: rejects ") + testCase.name);
	}
	// A damaged marker is managed state, so it must never read as absent:
	// that is the difference between "import again" and "unmanaged session".
	writeFile(path("marker-damaged"), "garbage");
	check(readMarker(path("marker-damaged"), read) != MarkerStatus::Absent,
			"marker: damage never looks like an unmanaged launch");
}

static void testMarkerWriteFailuresPreservePrevious()
{
	const std::string file = path("marker-protected");
	Marker good;
	good.transition = Transition::Accepted;
	good.revision = 3;
	good.account = "player-one";
	check(writeMarker(file, good), "marker: seed an accepted marker");
	const std::string before = readFile(file);

	// A directory where the temporary file belongs: the same observable
	// failure as a full or read-only card, without needing either.
	const std::string blocker = file + ".tmp";
	check(mkdir(blocker.c_str(), 0755) == 0, "marker: block the temporary path");
	Marker pending;
	pending.transition = Transition::Pending;
	pending.revision = 4;
	pending.account = "player-two";
	check(!writeMarker(file, pending), "marker: a failed write reports failure");
	check(readFile(file) == before, "marker: a failed write keeps the previous marker");
	rmdir(blocker.c_str());

	Marker read;
	check(readMarker(file, read) == MarkerStatus::Ok && read.revision == 3
			&& read.account == "player-one",
			"marker: the previous revision is still the accepted one");

	// A missing directory is the other write failure the bridge must survive.
	check(!writeMarker(path("no-such-directory/marker"), pending),
			"marker: writing into a missing directory fails cleanly");

	// An account with a newline would forge a second key on read.
	Marker forged;
	forged.transition = Transition::Accepted;
	forged.revision = 5;
	forged.account = "player\nstate signed-out";
	check(!writeMarker(path("marker-forged"), forged),
			"marker: refuses an account containing a line break");
}

static void testFirstImport()
{
	const Snapshot snapshot = configuredSnapshot("player-one", "correct horse", 1);
	check(snapshot.handoff == Handoff::Valid, "first import: the snapshot is valid");
	Marker none;
	const Decision decision = decide(snapshot, MarkerStatus::Absent, none, "", false);
	check(decision.action == Action::ImportLogin, "first import: authenticates the snapshot");
	check(decision.reason == "first-import", "first import: reports first-import");
	check(decision.account == "player-one" && decision.revision == 1,
			"first import: carries the account and revision");
}

static void testTokenReuseRequiresFullAgreement()
{
	const Snapshot snapshot = configuredSnapshot("player-one", "correct horse", 4);
	Marker accepted;
	accepted.transition = Transition::Accepted;
	accepted.revision = 4;
	accepted.account = "player-one";

	check(decide(snapshot, MarkerStatus::Ok, accepted, "player-one", true).action
			== Action::ReuseToken,
			"reuse: marker, snapshot and persisted account agree");

	// Each disagreement on its own must fall back to a fresh login.
	check(decide(snapshot, MarkerStatus::Ok, accepted, "player-one", false).action
			== Action::ImportLogin,
			"reuse: refused when no token is persisted");
	check(decide(snapshot, MarkerStatus::Ok, accepted, "someone-else", true).action
			== Action::ImportLogin,
			"reuse: refused when the persisted account differs");

	Marker pending = accepted;
	pending.transition = Transition::Pending;
	check(decide(snapshot, MarkerStatus::Ok, pending, "player-one", true).action
			== Action::ImportLogin,
			"reuse: a pending marker is never proof of a usable token");
	check(decide(snapshot, MarkerStatus::Ok, pending, "player-one", true).reason
			== "marker-pending",
			"reuse: a pending marker is reported as such");

	Marker olderRevision = accepted;
	olderRevision.revision = 3;
	const Decision changed = decide(snapshot, MarkerStatus::Ok, olderRevision, "player-one", true);
	check(changed.action == Action::ImportLogin && changed.reason == "revision-changed",
			"reuse: a password change (new revision, same user) forces a new login");

	Marker otherAccount = accepted;
	otherAccount.account = "player-two";
	const Decision switched = decide(snapshot, MarkerStatus::Ok, otherAccount, "player-two", true);
	check(switched.action == Action::ImportLogin && switched.reason == "account-changed",
			"reuse: a changed username forces a new login");

	check(decide(snapshot, MarkerStatus::Malformed, accepted, "player-one", true).action
			== Action::ImportLogin,
			"reuse: a damaged marker forces a new login");
}

static void testSignOut()
{
	const Snapshot snapshot = simpleSnapshot("signed-out", 6);
	check(snapshot.handoff == Handoff::Valid, "sign-out: the snapshot is valid");

	Marker accepted;
	accepted.transition = Transition::Accepted;
	accepted.revision = 5;
	accepted.account = "player-one";
	const Decision decision = decide(snapshot, MarkerStatus::Ok, accepted, "player-one", true);
	check(decision.action == Action::SignOut && decision.revision == 6,
			"sign-out: clears the managed account and records the retained revision");

	// A lost marker must not revive the old credentials.
	Marker none;
	check(decide(snapshot, MarkerStatus::Absent, none, "player-one", true).action
			== Action::SignOut,
			"sign-out: a lost marker still signs out");

	Marker committed;
	committed.transition = Transition::SignedOut;
	committed.revision = 6;
	check(decide(snapshot, MarkerStatus::Ok, committed, "", false).action == Action::Idle,
			"sign-out: an already committed sign-out is idle");

	Marker olderSignOut = committed;
	olderSignOut.revision = 2;
	check(decide(snapshot, MarkerStatus::Ok, olderSignOut, "", false).action == Action::SignOut,
			"sign-out: an older recorded sign-out is committed again");
}

static void testNeverConfigured()
{
	const Snapshot snapshot = simpleSnapshot("never-configured", 0);
	check(snapshot.handoff == Handoff::Valid, "never-configured: the snapshot is valid");

	Marker none;
	check(decide(snapshot, MarkerStatus::Absent, none, "native-user", true).action
			== Action::Unmanaged,
			"never-configured: an independently configured native account is preserved");

	Marker accepted;
	accepted.transition = Transition::Accepted;
	accepted.revision = 2;
	accepted.account = "player-one";
	const Decision decision = decide(snapshot, MarkerStatus::Ok, accepted, "player-one", true);
	check(decision.action == Action::SignOut && decision.revision == 0,
			"never-configured: managed credentials are cleared when a marker exists");
}

static void testInvalidAndUnreadableAreNotSignOut()
{
	Marker accepted;
	accepted.transition = Transition::Accepted;
	accepted.revision = 2;
	accepted.account = "player-one";

	for (const char *state : { "invalid", "unreadable" })
	{
		const Snapshot snapshot = simpleSnapshot(state, 0);
		check(snapshot.handoff == Handoff::Valid,
				std::string("handoff ") + state + ": is a valid handoff");
		const Decision managed = decide(snapshot, MarkerStatus::Ok, accepted, "player-one", true);
		check(managed.action == Action::SuppressManaged,
				std::string("handoff ") + state + ": suppresses managed authentication");
		check(managed.action != Action::SignOut,
				std::string("handoff ") + state + ": is never treated as sign-out");

		Marker none;
		check(decide(snapshot, MarkerStatus::Absent, none, "native-user", true).action
				== Action::Unmanaged,
				std::string("handoff ") + state + ": leaves an unmanaged native account alone");
	}
}

static void testMissingAndMalformedHandoff()
{
	std::map<std::string, std::string> empty;
	const Snapshot none = classify(empty);
	check(none.handoff == Handoff::None, "no handoff: classified as unmanaged");

	Marker marker;
	check(decide(none, MarkerStatus::Absent, marker, "native-user", true).action
			== Action::Unmanaged,
			"no handoff: an unmanaged launch stays native");

	Marker accepted;
	accepted.transition = Transition::Accepted;
	accepted.revision = 2;
	accepted.account = "player-one";
	const Decision managed = decide(none, MarkerStatus::Ok, accepted, "player-one", true);
	check(managed.action == Action::SuppressManaged && managed.reason == "handoff-missing",
			"no handoff: managed state cannot silently become an unmanaged session");

	std::map<std::string, std::string> partial;
	partial["UMRK_RA_ACCOUNT_STATE"] = "configured";
	const Snapshot malformed = classify(partial);
	check(malformed.handoff == Handoff::Malformed, "malformed handoff: refused");
	check(decide(malformed, MarkerStatus::Ok, accepted, "player-one", true).action
			== Action::SuppressManaged,
			"malformed handoff: never revives the accepted token");
	check(decide(malformed, MarkerStatus::Absent, marker, "native-user", true).action
			== Action::Idle,
			"malformed handoff: reported, but an unmanaged native account is untouched");
}

static void testCredentialsAreNotCarriedOutOfARejectedSnapshot()
{
	std::map<std::string, std::string> env;
	env["UMRK_RA_ACCOUNT_VERSION"] = "1";
	env["UMRK_RA_ACCOUNT_STATE"] = "configured";
	env["UMRK_RA_ACCOUNT_USERNAME"] = std::string(64, 'a');
	env["UMRK_RA_ACCOUNT_PASSWORD"] = "correct horse";
	env["UMRK_RA_ACCOUNT_REVISION"] = "4";
	const Snapshot snapshot = classify(env);
	check(snapshot.handoff == Handoff::Malformed, "oversized username: refused");
	check(snapshot.username.empty() && snapshot.password.empty(),
			"oversized username: no credential leaves the classifier");
	check(snapshot.revision == 0, "oversized username: no revision leaves the classifier");
}

int main()
{
	char templateName[] = "/tmp/umrk-ra-account-test-XXXXXX";
	const char *root = mkdtemp(templateName);
	if (root == nullptr) {
		fprintf(stderr, "cannot create a temporary directory\n");
		return 2;
	}
	tempRoot = root;

	testMarkerRoundTrip();
	testMarkerRejectsDamage();
	testMarkerWriteFailuresPreservePrevious();
	testFirstImport();
	testTokenReuseRequiresFullAgreement();
	testSignOut();
	testNeverConfigured();
	testInvalidAndUnreadableAreNotSignOut();
	testMissingAndMalformedHandoff();
	testCredentialsAreNotCarriedOutOfARejectedSnapshot();

	if (failures != 0) {
		printf("%d of %d account state checks failed\n", failures, checks);
		return 1;
	}
	printf("All %d account state checks passed.\n", checks);
	return 0;
}
