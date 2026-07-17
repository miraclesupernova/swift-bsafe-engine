# Build the bytebeat reference harness on macOS/Linux.
#
#   make          - build ./bytebeat_harness
#   make run      - build and dump 8 reference WAVs to ../reference_wavs/
#   make clean    - remove the binary

CXX      ?= clang++
# -O0: several bytebeat formulas shift ints by values > 31 (e.g. song 5's
# `t >> ((t>>9)|(t>>8))` reaches 96 for some t). That is UB in C, and clang
# at -O2 exploits it inconsistently between builds. The real device masks
# shift amounts in hardware (matches Swift's `&>>` masked shifts). Build the
# reference harness at -O0 so it matches that runtime behavior deterministically.
CXXFLAGS ?= -std=c++17 -O0 -Wall -Wno-unused-variable -Wno-unused-but-set-variable

TARGET   := bytebeat_harness
SRC      := bytebeat_harness.cpp
OUT_DIR  := ../reference_wavs

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET)

.PHONY: run clean
run: $(TARGET)
	@mkdir -p $(OUT_DIR)
	./$(TARGET) $(OUT_DIR)

clean:
	rm -f $(TARGET)
