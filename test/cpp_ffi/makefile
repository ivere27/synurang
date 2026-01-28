CC := g++
CFLAGS := -fPIC -shared -Wall -O2
TEST_CFLAGS := -std=c++17 -Wall -O2

all: libsynurang_test_cpp.so

libsynurang_test_cpp.so: backend.cc
	$(CC) $(CFLAGS) -o $@ backend.cc

# FfiChannel unit tests
ffi_channel_test: ffi_channel_test.cc
	$(CC) $(TEST_CFLAGS) -o $@ ffi_channel_test.cc

test: ffi_channel_test
	./ffi_channel_test

clean:
	rm -f libsynurang_test_cpp.so ffi_channel_test
