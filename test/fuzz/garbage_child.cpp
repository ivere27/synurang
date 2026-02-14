#include <iostream>
#include <vector>
#include <random>
#include <thread>
#include <chrono>
#include <unistd.h>

/**
 * Garbage Child Fuzzer
 * 
 * This program is designed to be a "bad" gRPC process child.
 * It does NOT implement gRPC. Instead, it periodically spews 
 * random binary garbage to stdout and stderr to test if the 
 * parent process host (Go/C++/Rust) is robust enough to handle 
 * non-gRPC noise without crashing or leaking memory.
 */

int main() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<> dis(0, 255);
    std::uniform_int_distribution<> sleep_dis(10, 500);

    std::cerr << "Garbage child starting: I am not a gRPC server." << std::endl;

    while (true) {
        // Generate random garbage size
        int size = dis(gen) * 4;
        std::vector<char> garbage(size);
        for (int i = 0; i < size; ++i) {
            garbage[i] = static_cast<char>(dis(gen));
        }

        // Randomly choose stdout or stderr
        if (dis(gen) % 2 == 0) {
            std::cout.write(garbage.data(), garbage.size());
            std::cout.flush();
        } else {
            std::cerr.write(garbage.data(), garbage.size());
            std::cerr.flush();
        }

        // Nap for a bit
        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_dis(gen)));
    }

    return 0;
}
