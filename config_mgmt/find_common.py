import os
import glob
from expand import expand

'''
Given 2+ config files as input, identify common option lines.
Write these lines to a new "common config" file.
Delete each from the input files.
Add an "#include" to the input files
'''

def read_config(file_path):
    with open(file_path, 'r') as file:
        return {line.strip() for line in file if '=' in line}

def find_common_opts(config_files):
    common_opts = None
    for file_path in config_files:
        config = read_config(file_path)
        if common_opts is None:
            common_opts = config
        else:
            common_opts &= config

    return common_opts

def commonize(config_files, common_file):
    '''
    For each config in config_files, identify common options and write them to common_file.
    Then rewrite each config file to remove the common options and add an #include to common_file.
    This removes redundant information
    '''
    # First we need to expand each config file
    expanded_config_files = []
    for f in config_files:
        expand(f, f + ".expanded")
        expanded_config_files.append(f + ".expanded")

    common_opts = find_common_opts(expanded_config_files)

    # Convert common_file to a relative path to the input files. Assumes all configs are in same dir
    common_file = os.path.relpath(common_file, os.path.dirname(config_files[0]))

    # Output the common configuration options
    with open(common_file, 'w') as file:
        for config in sorted(common_opts):
            file.write(config + '\n')
    print(f"{len(common_opts)} common configuration options saved to {common_file}")

    # Now let's rewrite the input files.
    for fname in config_files:
        with open(fname, 'r') as file:
            config = file.readlines()

        with open(fname, 'w') as file:
            file.write(f"#include {common_file}\n")
            for line in config:
                strip_line = line.strip()
                if strip_line not in common_opts:
                    file.write(line)

if __name__ == '__main__':
    from sys import argv
    if len(argv) > 3:
       commonize(argv[1:-1], argv[-1])
    else:
        raise RuntimeError(f"USAGE {argv[0]} [paths to config files...] [output.config]")

