# Zigini

A Zig library to read/write an ini file using a struct.

Zig Version: 0.11.0

## Usage

An example is provided in example/example.zig

To run the example, just type: `zig build example`

### Note

When using writeFromStruct, only fields that differ from the default value will be written to the file.
