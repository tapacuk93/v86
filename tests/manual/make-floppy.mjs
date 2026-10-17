#!/usr/bin/env node
// Build a 1.44 MB FAT12 floppy image holding one file, with a long name.
//
// Windows Setup looks for `autounattend.xml` on removable media before it draws anything, which is
// how an installation is made to run without a person at the keyboard. The name is longer than
// 8.3, so the directory entry has to carry the vfat long name records that go with it - a short
// name alone would be AUTOUNA~1.XML, which setup does not look for.
//
// Written out here rather than made with the host's tools because newfs_msdos will not format a
// plain file, and the alternative is a sequence of hdiutil attach and detach that needs the image
// mounted to put one small file in it. The layout below is the standard one for this geometry and
// is the whole of what is needed.
//
// Usage: make-floppy.mjs out.img name.ext < contents
import fs from "node:fs";

const [, , out, name] = process.argv;
if(!out || !name)
{
    console.error("usage: make-floppy.mjs out.img name.ext < contents");
    process.exit(2);
}
const contents = fs.readFileSync(0);

const SECTOR = 512;
const SECTORS = 2880;                       // 1.44 MB
const RESERVED = 1;
const FATS = 2;
const SECTORS_PER_FAT = 9;
const ROOT_ENTRIES = 224;
const ROOT_SECTORS = (ROOT_ENTRIES * 32) / SECTOR;          // 14
const DATA_START = RESERVED + FATS * SECTORS_PER_FAT + ROOT_SECTORS;   // 33

const image = Buffer.alloc(SECTORS * SECTOR, 0);

// ---- boot sector, which is only a parameter block here: nothing boots off this disk
const b = image;
b.set([0xEB, 0x3C, 0x90], 0);               // a jump, because every one of these starts with one
b.write("MSWIN4.1", 3, 8, "ascii");
b.writeUInt16LE(SECTOR, 11);
b[13] = 1;                                  // sectors per cluster
b.writeUInt16LE(RESERVED, 14);
b[16] = FATS;
b.writeUInt16LE(ROOT_ENTRIES, 17);
b.writeUInt16LE(SECTORS, 19);
b[21] = 0xF0;                               // media descriptor for a 1.44 MB floppy
b.writeUInt16LE(SECTORS_PER_FAT, 22);
b.writeUInt16LE(18, 24);                    // sectors per track
b.writeUInt16LE(2, 26);                     // heads
b[38] = 0x29;                               // extended boot signature, so the three fields follow
b.writeUInt32LE(0x12345678, 39);            // volume id
b.write("UNATTEND   ", 43, 11, "ascii");
b.write("FAT12   ", 54, 8, "ascii");
b.writeUInt16LE(0xAA55, 510);

// ---- the fat, one chain from cluster 2 to the end of the file
const clusters = Math.max(1, Math.ceil(contents.length / SECTOR));
const fat = Buffer.alloc(SECTORS_PER_FAT * SECTOR, 0);
const set_entry = (n, value) => {
    const offset = Math.floor(n * 3 / 2);
    if(n & 1)
    {
        fat[offset] = (fat[offset] & 0x0F) | ((value & 0x0F) << 4);
        fat[offset + 1] = (value >> 4) & 0xFF;
    }
    else
    {
        fat[offset] = value & 0xFF;
        fat[offset + 1] = (fat[offset + 1] & 0xF0) | ((value >> 8) & 0x0F);
    }
};
set_entry(0, 0xFF0);                        // the media descriptor again, as the first entry
set_entry(1, 0xFFF);
for(let i = 0; i < clusters; i++) set_entry(2 + i, i === clusters - 1 ? 0xFFF : 3 + i);
for(let copy = 0; copy < FATS; copy++) fat.copy(image, (RESERVED + copy * SECTORS_PER_FAT) * SECTOR);

// ---- the directory: the long name records first, in reverse, then the short one they belong to
const dot = name.lastIndexOf(".");
const base = (dot === -1 ? name : name.slice(0, dot)).toUpperCase();
const ext = (dot === -1 ? "" : name.slice(dot + 1)).toUpperCase();
// A name too long for 8.3 is given the usual ~1 short name, which is what the long records are
// checksummed against.
const short = (base.length > 8 ? base.slice(0, 6) + "~1" : base.padEnd(8)).padEnd(8).slice(0, 8) +
    ext.padEnd(3).slice(0, 3);

let checksum = 0;
for(let i = 0; i < 11; i++) checksum = (((checksum & 1) << 7) + (checksum >> 1) + short.charCodeAt(i)) & 0xFF;

const utf16 = Buffer.from(name + "\0", "utf16le");
const parts = Math.ceil(utf16.length / 26);
const dir = [];
for(let part = parts; part >= 1; part--)
{
    const entry = Buffer.alloc(32, 0xFF);
    entry[0] = part | (part === parts ? 0x40 : 0);   // the last fragment is flagged as first
    entry[11] = 0x0F;                                // the attribute that marks a long name record
    entry[12] = 0;
    entry[13] = checksum;
    entry[26] = 0;
    entry[27] = 0;
    // thirteen utf-16 characters, split across the three runs this record has room for
    const chunk = Buffer.alloc(26, 0xFF);
    utf16.copy(chunk, 0, (part - 1) * 26, Math.min(part * 26, utf16.length));
    chunk.copy(entry, 1, 0, 10);
    chunk.copy(entry, 14, 10, 22);
    chunk.copy(entry, 28, 22, 26);
    dir.push(entry);
}
const entry = Buffer.alloc(32, 0);
entry.write(short, 0, 11, "ascii");
entry[11] = 0x20;                           // archive
entry.writeUInt16LE(0x4800, 22);            // a time and date, which nothing here reads
entry.writeUInt16LE(0x5891, 24);
entry.writeUInt16LE(2, 26);                 // first cluster
entry.writeUInt32LE(contents.length, 28);
dir.push(entry);

let at = (RESERVED + FATS * SECTORS_PER_FAT) * SECTOR;
for(const e of dir) { e.copy(image, at); at += 32; }

contents.copy(image, DATA_START * SECTOR);
fs.writeFileSync(out, image);
console.log(`${out}: ${name}, ${contents.length} bytes in ${clusters} cluster(s)`);
