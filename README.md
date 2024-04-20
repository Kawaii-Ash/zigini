# Zigini

A Zig library to read/write an ini file using a struct.

This library follows the Zig master branch. Check releases if you're using an old version.

## Usage

An example is provided in example/example.zig

To run the example, just type: `zig build example`

### Note

When using writeFromStruct, only fields that differ from the default value will be written to the file.
