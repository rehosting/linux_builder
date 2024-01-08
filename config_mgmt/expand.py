'''
Given a config file, replace #includes it contains with the contents of the included file.
'''

import os

def expand(config_file, out_file):
    with open(config_file, 'r') as file:
        config = file.readlines()

    # Get relative path of config_file
    this_dir = os.path.dirname(os.path.abspath(config_file))

    with open(out_file, 'w') as file:
        for line in config:
            if line.startswith("#include"):
                include_file = os.path.join(this_dir, line.split()[1])

                with open(include_file, 'r') as include:
                    file.write(include.read())
            else:
                file.write(line)

if __name__ == '__main__':
    from sys import argv
    if len(argv) == 3:
        expand(argv[1], argv[2])
    else:
        raise RuntimeError(f"USAGE {argv[0]} [config file] [output file]")