#pragma once
#include <cstring>

inline bool supportedRuntime(const char *obsVersion, const char *qtVersion)
{
    return obsVersion && qtVersion && std::strcmp(obsVersion, "32.2.2") == 0 &&
           std::strcmp(qtVersion, "6.11.1") == 0;
}
