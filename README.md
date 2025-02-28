# rcopy - Remote Copy Tool

**rcopy** is a versatile and powerful Bash function designed for efficient and customizable copying of files and directories, both locally and between remote systems. Leveraging the capabilities of `rsync`, `scp`, and additional features like compression, file exclusion, and bandwidth control, **rcopy** aims to simplify and enhance the process of data transfer.

## Installation

Due to its comprehensive functionality, **rcopy** is best sourced from outside your `.bashrc` file to keep your shell configuration clean and fast. You can source the script whenever needed or in specific scripts that require its functionality.

1. Clone the repository or download the `rcopy.sh` script to your preferred location.

```bash
git clone https://github.com/mrAibo/rcopy.git
```

2. Source the script in your terminal or within a script:

```bash
source /path/to/rcopy.sh
```

## Features

- **Dual Protocol Support**: Choose between `rsync` (default) or `scp`
- **Compression**: Optional GZIP compression for slow networks
- **Sync Mode**: Server-to-server synchronization with date filtering
- **Bandwidth Control**: Limit transfer speed (rsync only)
- **Exclusion Patterns**: Support for both inline patterns and exclude files
- **SSH Integration**: Custom ports, keys, and SSH config compatibility
- **Autocomplete**: Intelligent path completion for local/remote files
- **Verbose Mode**: Detailed transfer progress visualization

## Usage

```bash
rcopy [OPTIONS] source destination
```

### Options

- `-h`, `--help`: Show help message.
- `-z`, `--compress`: Compress data during transfer.
- `-m`, `--move`: Move files instead of copying (delete source after transfer).
- `-u`, `--user`: Specify remote username.
- `-p`, `--port`: Specify SSH port number.
- `-i`, `--identity`: Specify SSH identity file (private key).
- `-l`, `--limit`: Limit bandwidth (KB/s, rsync only).
- `-e`, `--exclude`: Exclude files matching pattern or use exclude file.
- `-s`, `--use-scp`: Force using SCP instead of rsync.
- `-v`, `--verbose`: Show detailed progress information.
- `-S`, `--sync`: Enable sync mode between remote servers.
- `--source-host`: Source server hostname/IP.
- `--target-host`: Target server hostname/IP.
- `--days`: Sync files modified in last DAYS days.

### Examples

**Basic Examples**

- Copy a local directory:

```bash
rcopy ~/documents/project /backup/
```

- Copy to a remote server:

```bash
rcopy ~/documents user@server:/backup/
```

- Copy from a remote server:

```bash
rcopy user@server:/remote/data ~/local/
```

**Advanced Examples**

- Compress and move with verbose output:

```bash
rcopy -z -m -v ~/large-project server:/backup/
```

- Exclude log files and use custom SSH port:

```bash
rcopy -e "*.log" -p 2222 ~/project user@server:/backup/
```

- Enable direct server-to-server transfers with -S/--sync:

```bash
rcopy -S --source-host HOST1 --target-host HOST2 /src /dest

Sync Options:

--days N: Only sync files modified in last N days

Combine with -m to move files after sync
```

## Performance Tips
- **Use compression (-z) for**:
Text files and small documents, 
High-latency connections, 
Transfers with many small files
- **Prefer rsync for**:
Large directories, 
Partial transfers, 
Network-efficient updates
- **Use SCP (-s) for**:
Single large files, 
Simple transfers without advanced features

## License

rcopy is licensed under the GNU General Public License v3.0.

## Contributing

Contributions are welcome! If you find any bugs, have feature requests, or would like to contribute, please open an issue or submit a pull request.

## Acknowledgements

rcopy utilizes the power of existing tools like `rsync`, `scp`, `ssh`, `tar`, and `gzip` to deliver a seamless data transfer experience.

---

**Note**: The detailed explanation and usage examples are provided within the `rcopy.sh` script. Refer to the script for in-depth documentation and advanced usage scenarios.

---

Happy copying! 🚀
