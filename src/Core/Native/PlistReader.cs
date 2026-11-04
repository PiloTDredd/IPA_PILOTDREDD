// Разбор property list (XML и бинарный bplist00) в словари/списки .NET.
// Совместимо с компилятором C# 5 (Windows PowerShell 5.1, Add-Type).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Xml;

namespace IPADredd
{
    public static class PlistReader
    {
        public static object Parse(byte[] data)
        {
            if (data == null || data.Length == 0) { throw new ArgumentException("Empty plist"); }
            if (data.Length >= 8 && Encoding.ASCII.GetString(data, 0, 6) == "bplist")
            {
                return new BinaryPlist(data).Parse();
            }
            return ParseXml(data);
        }

        // ---------- XML ----------

        private static object ParseXml(byte[] data)
        {
            XmlDocument doc = new XmlDocument();
            doc.XmlResolver = null;
            XmlReaderSettings settings = new XmlReaderSettings();
            settings.DtdProcessing = DtdProcessing.Ignore;
            settings.XmlResolver = null;
            using (System.IO.MemoryStream ms = new System.IO.MemoryStream(data))
            using (XmlReader reader = XmlReader.Create(ms, settings))
            {
                doc.Load(reader);
            }
            XmlNode root = doc.DocumentElement;
            if (root == null) { throw new FormatException("No root element"); }
            if (root.Name == "plist")
            {
                foreach (XmlNode child in root.ChildNodes)
                {
                    if (child.NodeType == XmlNodeType.Element) { return ParseXmlNode(child); }
                }
                return null;
            }
            return ParseXmlNode(root);
        }

        private static object ParseXmlNode(XmlNode node)
        {
            switch (node.Name)
            {
                case "dict":
                    Dictionary<string, object> dict = new Dictionary<string, object>(StringComparer.Ordinal);
                    string key = null;
                    foreach (XmlNode child in node.ChildNodes)
                    {
                        if (child.NodeType != XmlNodeType.Element) { continue; }
                        if (child.Name == "key") { key = child.InnerText; continue; }
                        if (key != null) { dict[key] = ParseXmlNode(child); key = null; }
                    }
                    return dict;
                case "array":
                    List<object> list = new List<object>();
                    foreach (XmlNode child in node.ChildNodes)
                    {
                        if (child.NodeType == XmlNodeType.Element) { list.Add(ParseXmlNode(child)); }
                    }
                    return list;
                case "string": return node.InnerText;
                case "integer":
                    long l;
                    if (long.TryParse(node.InnerText.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out l)) { return l; }
                    return node.InnerText;
                case "real":
                    double d;
                    if (double.TryParse(node.InnerText.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d)) { return d; }
                    return node.InnerText;
                case "true": return true;
                case "false": return false;
                case "date":
                    DateTime dt;
                    if (DateTime.TryParse(node.InnerText, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out dt)) { return dt; }
                    return node.InnerText;
                case "data":
                    try { return Convert.FromBase64String(node.InnerText.Trim()); }
                    catch (FormatException) { return new byte[0]; }
                default: return node.InnerText;
            }
        }

        // ---------- Binary ----------

        private sealed class BinaryPlist
        {
            private readonly byte[] _d;
            private int _offsetSize;
            private int _refSize;
            private long _numObjects;
            private long _topObject;
            private long _offsetTable;
            private int _depth;

            public BinaryPlist(byte[] data) { _d = data; }

            public object Parse()
            {
                if (_d.Length < 40) { throw new FormatException("Binary plist too short"); }
                int t = _d.Length - 32;
                _offsetSize = _d[t + 6];
                _refSize = _d[t + 7];
                _numObjects = ReadBE(t + 8, 8);
                _topObject = ReadBE(t + 16, 8);
                _offsetTable = ReadBE(t + 24, 8);
                if (_offsetSize < 1 || _offsetSize > 8 || _refSize < 1 || _refSize > 8) { throw new FormatException("Bad trailer"); }
                if (_offsetTable < 8 || _offsetTable + _numObjects * _offsetSize > t) { throw new FormatException("Bad offset table"); }
                return ReadObject(_topObject);
            }

            private long ReadBE(long pos, int size)
            {
                if (pos < 0 || pos + size > _d.Length) { throw new FormatException("Out of range"); }
                long v = 0;
                for (int i = 0; i < size; i++) { v = (v << 8) | _d[pos + i]; }
                return v;
            }

            private long ObjectOffset(long index)
            {
                if (index < 0 || index >= _numObjects) { throw new FormatException("Bad object ref"); }
                return ReadBE(_offsetTable + index * _offsetSize, _offsetSize);
            }

            private long ReadLength(long pos, int info, out long start)
            {
                start = pos + 1;
                if (info != 0x0F) { return info; }
                int marker = _d[pos + 1];
                if ((marker & 0xF0) != 0x10) { throw new FormatException("Bad length marker"); }
                int bytes = 1 << (marker & 0x0F);
                start = pos + 2 + bytes;
                return ReadBE(pos + 2, bytes);
            }

            private object ReadObject(long index)
            {
                if (++_depth > 256) { throw new FormatException("Plist nesting too deep"); }
                try
                {
                    long pos = ObjectOffset(index);
                    if (pos < 0 || pos >= _d.Length) { throw new FormatException("Bad object offset"); }
                    int marker = _d[pos];
                    int type = marker >> 4;
                    int info = marker & 0x0F;
                    long start;
                    long len;
                    switch (type)
                    {
                        case 0x0:
                            if (info == 0x8) { return false; }
                            if (info == 0x9) { return true; }
                            return null;
                        case 0x1:
                            return ReadBE(pos + 1, 1 << info);
                        case 0x2:
                            int size = 1 << info;
                            byte[] raw = new byte[size];
                            Array.Copy(_d, pos + 1, raw, 0, size);
                            if (BitConverter.IsLittleEndian) { Array.Reverse(raw); }
                            return size == 4 ? (double)BitConverter.ToSingle(raw, 0) : BitConverter.ToDouble(raw, 0);
                        case 0x3:
                            byte[] rd = new byte[8];
                            Array.Copy(_d, pos + 1, rd, 0, 8);
                            if (BitConverter.IsLittleEndian) { Array.Reverse(rd); }
                            return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(BitConverter.ToDouble(rd, 0));
                        case 0x4:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len);
                            byte[] bytes = new byte[len];
                            Array.Copy(_d, start, bytes, 0, len);
                            return bytes;
                        case 0x5:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len);
                            return Encoding.ASCII.GetString(_d, (int)start, (int)len);
                        case 0x6:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len * 2);
                            return Encoding.BigEndianUnicode.GetString(_d, (int)start, (int)(len * 2));
                        case 0x7:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len);
                            return Encoding.UTF8.GetString(_d, (int)start, (int)len);
                        case 0x8:
                            return ReadBE(pos + 1, info + 1);
                        case 0xA:
                        case 0xC:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len * _refSize);
                            List<object> list = new List<object>();
                            for (long i = 0; i < len; i++) { list.Add(ReadObject(ReadBE(start + i * _refSize, _refSize))); }
                            return list;
                        case 0xD:
                            len = ReadLength(pos, info, out start);
                            CheckRange(start, len * 2 * _refSize);
                            Dictionary<string, object> dict = new Dictionary<string, object>(StringComparer.Ordinal);
                            for (long i = 0; i < len; i++)
                            {
                                object k = ReadObject(ReadBE(start + i * _refSize, _refSize));
                                object v = ReadObject(ReadBE(start + (len + i) * _refSize, _refSize));
                                dict[Convert.ToString(k, CultureInfo.InvariantCulture)] = v;
                            }
                            return dict;
                        default:
                            throw new FormatException("Unsupported object type 0x" + type.ToString("X"));
                    }
                }
                finally { _depth--; }
            }

            private void CheckRange(long start, long len)
            {
                if (start < 0 || len < 0 || start + len > _d.Length) { throw new FormatException("Object out of range"); }
            }
        }

        // ---------- Helpers for PowerShell ----------

        public static string GetString(object dict, string key)
        {
            IDictionary d = dict as IDictionary;
            if (d == null || !d.Contains(key) || d[key] == null) { return null; }
            object v = d[key];
            if (v is byte[]) { return null; }
            return Convert.ToString(v, CultureInfo.InvariantCulture);
        }
    }
}
