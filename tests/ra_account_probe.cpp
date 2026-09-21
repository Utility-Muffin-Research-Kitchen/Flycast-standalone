// Host probe for the standalone-ra-account-v1 classifier that ships inside
// the emulator. It reads one byte-exact environment from stdin and prints the
// verdict, so run-contract-fixtures.py can replay the shared leaf-contracts
// fixtures through the SAME code the device runs.
//
// A fixture environment cannot go through getenv(): several cases carry bytes
// a C string could never hold (an embedded NUL truncates, 0xFF is not UTF-8).
// The framing is therefore explicit:
//
//   <name>\n<byte length>\n<raw bytes>   repeated until EOF
//
// Output is the kind on the first line, then one reason per line.
#include "achievements/ra_account.h"

#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

int main()
{
	std::vector<char> input;
	char chunk[4096];
	size_t read;
	while ((read = fread(chunk, 1, sizeof(chunk), stdin)) > 0)
		input.insert(input.end(), chunk, chunk + read);

	std::map<std::string, std::string> env;
	size_t offset = 0;
	const std::string data(input.begin(), input.end());
	while (offset < data.size())
	{
		const size_t nameEnd = data.find('\n', offset);
		if (nameEnd == std::string::npos)
			break;
		const std::string name = data.substr(offset, nameEnd - offset);
		const size_t lengthEnd = data.find('\n', nameEnd + 1);
		if (lengthEnd == std::string::npos)
			break;
		const size_t length = (size_t)std::stoul(data.substr(nameEnd + 1, lengthEnd - nameEnd - 1));
		if (lengthEnd + 1 + length > data.size())
			break;
		env[name] = data.substr(lengthEnd + 1, length);
		offset = lengthEnd + 1 + length;
	}

	using namespace achievements::ra_account;
	const Snapshot snapshot = classify(env);
	switch (snapshot.handoff)
	{
	case Handoff::None:
		std::cout << "unmanaged\n";
		break;
	case Handoff::Valid:
		std::cout << "valid-handoff\n";
		break;
	case Handoff::Malformed:
		std::cout << "invalid-handoff\n";
		break;
	}
	for (const std::string& reason : snapshot.reasons)
		std::cout << reason << "\n";
	return 0;
}
