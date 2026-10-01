//! Local read-only GGUF v3 inspection. No tensor decoding or backend execution.
use anyhow::{bail, Context, Result};
use clap::{Args, ValueEnum};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const HEADER_LIMIT: u64 = 128 * 1024 * 1024;
const LLAMA_REVISION: &str = "c96ffc869";
#[derive(Args)]
pub struct InspectArgs {
    #[arg(long)]
    model: PathBuf,
    /// Local binary is hashed, never executed. Revision is a supplied assertion.
    #[arg(long)]
    backend_binary: PathBuf,
    /// Only the reviewed llama.cpp 8805 source revision is supported by this slice.
    #[arg(long)]
    backend_revision: String,
    /// Per-request configured context, not llama-server's shared slot budget.
    #[arg(long)]
    context_tokens: u64,
    #[arg(long)]
    concurrency: u64,
    #[arg(long, value_enum)]
    kv_codec: Codec,
}
#[derive(Clone, Copy, ValueEnum, Serialize)]
enum Codec {
    F16,
    #[value(name = "q4_0")]
    Q4_0,
    #[value(name = "q8_0")]
    Q8_0,
}
impl Codec {
    fn layout(self) -> (u64, u64) {
        match self {
            Self::F16 => (1, 2),
            Self::Q4_0 => (32, 18),
            Self::Q8_0 => (32, 34),
        }
    }
}
#[derive(Debug, Serialize)]
#[serde(untagged)]
enum Scalar {
    Integer(u64),
    Text(String),
    Other,
}
struct Directory {
    scalars: BTreeMap<String, Scalar>,
    metadata_keys: Vec<String>,
    tensors: Vec<Tensor>,
    data_start: u64,
    file_bytes: u64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Tensor {
    name: String,
    dimensions: Vec<u64>,
    encoding: u32,
    offset: u64,
    bytes: u64,
}
struct Reader {
    inner: BufReader<File>,
    end: u64,
}
impl Reader {
    fn position(&mut self) -> Result<u64> {
        Ok(self.inner.stream_position()?)
    }
    fn take<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.bound(N as u64)?;
        let mut b = [0; N];
        self.inner.read_exact(&mut b)?;
        Ok(b)
    }
    fn bound(&mut self, n: u64) -> Result<()> {
        if self
            .position()?
            .checked_add(n)
            .context("header offset overflow")?
            > self.end
        {
            bail!("GGUF header exceeds file or 128 MiB limit");
        }
        Ok(())
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take()?))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take()?))
    }
    fn text(&mut self, retain: bool) -> Result<String> {
        let n = self.u64()?;
        self.bound(n)?;
        if !retain {
            self.inner.seek(SeekFrom::Current(i64::try_from(n)?))?;
            return Ok(String::new());
        }
        if n > 1024 * 1024 {
            bail!("retained GGUF string exceeds 1 MiB");
        }
        let mut b = vec![0; usize::try_from(n)?];
        self.inner.read_exact(&mut b)?;
        Ok(String::from_utf8(b)?)
    }
    fn value(&mut self, ty: u32, retain: bool, depth: u8) -> Result<Scalar> {
        if depth > 1 {
            bail!("nested GGUF arrays unsupported");
        }
        Ok(match ty {
            0 => Scalar::Integer(u64::from(self.take::<1>()?[0])),
            2 => Scalar::Integer(u64::from(u16::from_le_bytes(self.take()?))),
            4 => Scalar::Integer(u64::from(self.u32()?)),
            10 => Scalar::Integer(self.u64()?),
            8 => Scalar::Text(self.text(retain)?),
            9 => {
                let item = self.u32()?;
                let n = self.u64()?;
                if n > 2_000_000 || item == 9 {
                    bail!("GGUF array count/type unsupported");
                }
                for _ in 0..n {
                    self.value(item, false, depth + 1)?;
                }
                Scalar::Other
            }
            1 | 7 => {
                self.take::<1>()?;
                Scalar::Other
            }
            3 => {
                self.take::<2>()?;
                Scalar::Other
            }
            5 | 6 => {
                self.take::<4>()?;
                Scalar::Other
            }
            11 | 12 => {
                self.take::<8>()?;
                Scalar::Other
            }
            _ => bail!("unknown GGUF metadata type {ty}"),
        })
    }
}
fn encoding(ty: u32) -> Result<(u64, u64)> {
    // Reviewed ggml block layouts. Unknown types fail closed, never use offsets as size.
    Ok(match ty {
        0 => (1, 4),
        1 => (1, 2),
        2 => (32, 18),
        3 => (32, 20),
        6 => (32, 22),
        7 => (32, 24),
        8 => (32, 34),

        10 => (256, 84),
        11 => (256, 110),
        12 => (256, 144),
        13 => (256, 176),
        14 => (256, 210),
        15 => (256, 292),
        30 => (1, 2),
        _ => bail!("unsupported tensor encoding {ty}"),
    })
}
fn parse(path: &Path) -> Result<Directory> {
    let file = File::open(path)?;
    if !file.metadata()?.is_file() {
        bail!("model must be a regular file");
    }
    let file_bytes = file.metadata()?.len();
    let mut r = Reader {
        inner: BufReader::new(file),
        end: file_bytes.min(HEADER_LIMIT),
    };
    if &r.take::<4>()? != b"GGUF" || r.u32()? != 3 {
        bail!("only little-endian GGUF v3 is supported");
    }
    let nt = r.u64()?;
    let nm = r.u64()?;
    if nt == 0 || nt > 100_000 || nm > 100_000 {
        bail!("invalid GGUF directory counts");
    }
    let mut scalars = BTreeMap::new();
    let mut metadata_keys = Vec::new();
    for _ in 0..nm {
        let name = r.text(true)?;
        if scalars.contains_key(&name) {
            bail!("duplicate metadata key {name}");
        }
        let ty = r.u32()?;
        let retain = name == "general.architecture"
            || name == "general.alignment"
            || name.starts_with("llama.")
            || name.starts_with("split.");
        let value = r.value(ty, retain, 0)?;
        metadata_keys.push(name.clone());
        scalars.insert(name, value);
    }
    if scalars.keys().any(|k| k.starts_with("split.")) {
        bail!("sharded GGUF unsupported: inspect all shards through a future producer");
    }
    let mut tensors = Vec::new();
    let mut names = BTreeSet::new();
    for _ in 0..nt {
        let name = r.text(true)?;
        if !names.insert(name.clone()) {
            bail!("duplicate tensor name");
        }
        let nd = r.u32()?;
        if !(1..=4).contains(&nd) {
            bail!("invalid tensor dimension count");
        }
        let mut dimensions = Vec::new();
        let mut elements = 1u64;
        for _ in 0..nd {
            let d = r.u64()?;
            if d == 0 {
                bail!("zero tensor dimension");
            }
            elements = elements.checked_mul(d).context("tensor shape overflow")?;
            dimensions.push(d);
        }
        let ty = r.u32()?;
        let offset = r.u64()?;
        let (block, size) = encoding(ty)?;
        if dimensions[0] % block != 0 {
            bail!("tensor row not divisible by encoding block");
        }
        let bytes = (elements / block)
            .checked_mul(size)
            .context("tensor byte overflow")?;
        tensors.push(Tensor {
            name,
            dimensions,
            encoding: ty,
            offset,
            bytes,
        });
    }
    let alignment = match scalars.get("general.alignment") {
        None => 32,
        Some(Scalar::Integer(v)) => *v,
        _ => bail!("invalid alignment type"),
    };
    if alignment == 0 || !alignment.is_power_of_two() || alignment > 65536 {
        bail!("invalid GGUF alignment");
    }
    let pos = r.position()?;
    let data_start = pos
        .checked_add(alignment - 1)
        .context("alignment overflow")?
        / alignment
        * alignment;
    let mut ranges = Vec::new();
    for t in &tensors {
        if t.offset % alignment != 0 {
            bail!("unaligned tensor offset");
        }
        let start = data_start
            .checked_add(t.offset)
            .context("tensor offset overflow")?;
        let end = start
            .checked_add(t.bytes)
            .context("tensor range overflow")?;
        if end > file_bytes {
            bail!("tensor range exceeds file");
        }
        ranges.push((start, end));
    }
    ranges.sort_unstable();
    if ranges.windows(2).any(|w| w[0].1 > w[1].0) {
        bail!("overlapping tensor ranges unsupported");
    }
    Ok(Directory {
        scalars,
        metadata_keys,
        tensors,
        data_start,
        file_bytes,
    })
}
fn integer(d: &Directory, key: &str) -> Result<u64> {
    match d.scalars.get(key) {
        Some(Scalar::Integer(v)) if *v > 0 => Ok(*v),
        _ => bail!("missing/invalid integer metadata {key}"),
    }
}
fn kv_payload(d: &Directory, context: u64, concurrency: u64, codec: Codec) -> Result<u64> {
    if context == 0 || concurrency == 0 {
        bail!("positive context/concurrency required");
    }
    if !matches!(d.scalars.get("general.architecture"),Some(Scalar::Text(s)) if s=="llama") {
        bail!("KV producer supports dense llama architecture only");
    }
    if context > integer(d, "llama.context_length")? {
        bail!("context exceeds trained context");
    }
    // Disallow features which change full-history GQA allocation.
    for key in d.scalars.keys().filter(|k| k.starts_with("llama.")) {
        if !(matches!(
            key.as_str(),
            "llama.block_count"
                | "llama.context_length"
                | "llama.embedding_length"
                | "llama.feed_forward_length"
                | "llama.attention.head_count"
                | "llama.attention.head_count_kv"
                | "llama.attention.key_length"
                | "llama.attention.value_length"
                | "llama.attention.layer_norm_rms_epsilon"
                | "llama.rope.dimension_count"
                | "llama.rope.freq_base"
                | "llama.vocab_size"
        ) || key.starts_with("llama.rope.scaling."))
        {
            bail!("unsupported llama feature {key}");
        }
    }
    let heads = integer(d, "llama.attention.head_count")?;
    let hidden = integer(d, "llama.embedding_length")?;
    let kv = integer(d, "llama.attention.head_count_kv")?;
    if hidden % heads != 0 || heads % kv != 0 {
        bail!("invalid GQA geometry");
    }
    let width = |key| -> Result<u64> {
        if d.scalars.contains_key(key) {
            integer(d, key)
        } else {
            Ok(hidden / heads)
        }
    };
    let wk = width("llama.attention.key_length")?;
    let wv = width("llama.attention.value_length")?;
    // Geometry is checked against every stored Q/K/V matrix, not the architecture label alone.
    let layers = integer(d, "llama.block_count")?;
    if layers > 100_000 {
        bail!("invalid layer count");
    }
    for layer in 0..layers {
        for (role, rows) in [
            ("attn_q", heads.checked_mul(wk)),
            ("attn_k", kv.checked_mul(wk)),
            ("attn_v", kv.checked_mul(wv)),
        ] {
            let rows = rows.context("GQA row overflow")?;
            let name = format!("blk.{layer}.{role}.weight");
            let t = d
                .tensors
                .iter()
                .find(|t| t.name == name)
                .with_context(|| format!("missing {name}"))?;
            if t.dimensions != [hidden, rows] {
                bail!("{name} shape incompatible with GQA geometry");
            }
        }
    }
    let (block, size) = codec.layout();
    let row = |w: u64| -> Result<u64> {
        let n = w.checked_mul(kv).context("KV width overflow")?;
        if n % block != 0 {
            bail!("KV row incompatible with codec");
        }
        (n / block).checked_mul(size).context("KV row overflow")
    };
    // Use 256-cell rounding conservatively for the reviewed revision, per request.
    let cells = context.checked_add(255).context("context overflow")? / 256 * 256;
    row(wk)?
        .checked_add(row(wv)?)
        .and_then(|v| v.checked_mul(layers))
        .and_then(|v| v.checked_mul(cells))
        .and_then(|v| v.checked_mul(concurrency))
        .context("KV payload overflow")
}
fn digest(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    if !file.metadata()?.is_file() {
        bail!("digest input must be a regular file");
    }
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn run(args: InspectArgs) -> Result<()> {
    if args.backend_revision != LLAMA_REVISION {
        bail!("KV formula reviewed only for llama.cpp {LLAMA_REVISION}; revision is asserted, not authenticated by binary hash");
    }
    let before = std::fs::metadata(&args.model)?;
    let binary_before = std::fs::metadata(&args.backend_binary)?;
    let d = parse(&args.model)?;
    let payload = kv_payload(&d, args.context_tokens, args.concurrency, args.kv_codec)?;
    let weights = d.tensors.iter().try_fold(0u64, |sum, t| {
        sum.checked_add(t.bytes).context("weight byte overflow")
    })?;
    let mut types = BTreeMap::new();
    for t in &d.tensors {
        *types.entry(t.encoding).or_insert(0u64) += 1;
    }
    let artifact_digest = digest(&args.model)?;
    let binary_digest = digest(&args.backend_binary)?;
    let after = std::fs::metadata(&args.model)?;
    let binary_after = std::fs::metadata(&args.backend_binary)?;
    if before.len() != after.len()
        || before.modified()? != after.modified()?
        || binary_before.len() != binary_after.len()
        || binary_before.modified()? != binary_after.modified()?
    {
        bail!("input changed during inspection; retry with immutable files");
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "version":1,"kind":"artifact_and_kv_payload_inspection","artifactSha256":artifact_digest,
            "backendBinarySha256":binary_digest,"backendRevisionAssertion":args.backend_revision,
            "fileBytes":d.file_bytes,"tensorPayloadBytes":weights,"dataStart":d.data_start,"tensorTypeCounts":types,
            "metadataKeys":d.metadata_keys,"architecture":d.scalars.get("general.architecture"),
            "contextTokensPerRequest":args.context_tokens,"concurrency":args.concurrency,"kvCodec":args.kv_codec,
            "modeledKvPayloadAllRequestsBytes":payload,"verdict":"not_assessed",
            "source":"https://github.com/ggml-org/llama.cpp/blob/c96ffc869/src/llama-kv-cache.cpp",
            "caveats":["Payload only: no fit verdict, peak scratch, buffer alignment, mmap resident copies, draft, live capacity or speed estimate.",
            "Binary digest identifies bytes but does not prove supplied source revision or runtime flags.",
            "256-cell rounding is conservative; llama-server context can be a combined slot budget. Input here is per request.",
            "Full files were read for digests, no model loaded, backend executed, network request or routing change."]
        }))?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    fn string(b: &mut Vec<u8>, s: &str) {
        b.extend((s.len() as u64).to_le_bytes());
        b.extend(s.as_bytes());
    }
    fn fixture() -> Vec<u8> {
        let mut b = b"GGUF".to_vec();
        b.extend(3u32.to_le_bytes());
        b.extend(3u64.to_le_bytes());
        b.extend(7u64.to_le_bytes());
        string(&mut b, "general.architecture");
        b.extend(8u32.to_le_bytes());
        string(&mut b, "llama");
        for (key, v) in [
            ("llama.block_count", 1),
            ("llama.context_length", 4096),
            ("llama.embedding_length", 32),
            ("llama.attention.head_count", 1),
            ("llama.attention.head_count_kv", 1),
        ] {
            string(&mut b, key);
            b.extend(4u32.to_le_bytes());
            b.extend((v as u32).to_le_bytes());
        }
        string(&mut b, "tokenizer.ggml.tokens");
        b.extend(9u32.to_le_bytes());
        b.extend(8u32.to_le_bytes());
        b.extend(2u64.to_le_bytes());
        string(&mut b, "hello");
        string(&mut b, "world");
        for (i, role) in ["attn_q", "attn_k", "attn_v"].iter().enumerate() {
            string(&mut b, &format!("blk.0.{role}.weight"));
            b.extend(2u32.to_le_bytes());
            b.extend(32u64.to_le_bytes());
            b.extend(32u64.to_le_bytes());
            b.extend(0u32.to_le_bytes());
            b.extend((i as u64 * 4096).to_le_bytes());
        }
        let start = b.len().div_ceil(32) * 32;
        b.resize(start + 3 * 4096, 0);
        b
    }
    fn write(b: &[u8]) -> tempfile::NamedTempFile {
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(b).unwrap();
        f
    }
    #[test]
    fn reads_directory_skips_tokens_and_derives_llama_default_head_width() {
        let f = write(&fixture());
        let d = parse(f.path()).unwrap();
        assert_eq!(d.tensors.len(), 3);
        assert_eq!(d.tensors.iter().map(|t| t.bytes).sum::<u64>(), 12288);
        assert_eq!(kv_payload(&d, 4096, 2, Codec::Q4_0).unwrap(), 294912);
        assert_eq!(kv_payload(&d, 1, 1, Codec::F16).unwrap(), 32768);
    }
    #[test]
    fn truncation_rejected_in_header_and_tensor_region() {
        let b = fixture();
        for n in [0, 4, 23, 50, 300, b.len() - 1] {
            assert!(parse(write(&b[..n]).path()).is_err());
        }
    }
    #[test]
    fn unsupported_header_versions_endianness_and_counts_rejected() {
        let mut b = fixture();
        b[4..8].copy_from_slice(&2u32.to_le_bytes());
        assert!(parse(write(&b).path()).is_err());
        b[4..8].copy_from_slice(&3u32.to_le_bytes());
        b[8..16].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(parse(write(&b).path()).is_err());
        b[..4].copy_from_slice(b"FUGG");
        assert!(parse(write(&b).path()).is_err());
    }
    #[test]
    fn unknown_encoding_and_geometry_fail_closed() {
        assert!(encoding(999).is_err());
        let f = write(&fixture());
        let mut d = parse(f.path()).unwrap();
        d.tensors[1].dimensions[1] = 16;
        assert!(kv_payload(&d, 4096, 1, Codec::F16).is_err());
    }
    #[test]
    fn architectures_hybrid_features_arrays_and_context_rejected() {
        let f = write(&fixture());
        let mut d = parse(f.path()).unwrap();
        assert!(kv_payload(&d, 4097, 1, Codec::Q4_0).is_err());
        assert!(kv_payload(&d, 4096, 0, Codec::Q4_0).is_err());
        d.scalars.insert(
            "llama.attention.sliding_window".into(),
            Scalar::Integer(128),
        );
        assert!(kv_payload(&d, 4096, 1, Codec::Q4_0).is_err());
        d.scalars.remove("llama.attention.sliding_window");
        d.scalars.insert("llama.block_count".into(), Scalar::Other);
        assert!(kv_payload(&d, 4096, 1, Codec::Q4_0).is_err());
        d.scalars.insert(
            "general.architecture".into(),
            Scalar::Text("qwen3next".into()),
        );
        assert!(kv_payload(&d, 4096, 1, Codec::Q4_0).is_err());
    }
    #[test]
    fn overflow_and_digest() {
        let f = write(&fixture());
        let d = parse(f.path()).unwrap();
        assert!(kv_payload(&d, 4096, u64::MAX, Codec::Q4_0).is_err());
        let f = write(b"abc");
        assert_eq!(
            digest(f.path()).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
    #[test]
    fn malformed_strings_and_nested_array_rejected() {
        let mut b = fixture();
        b[24..32].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(parse(write(&b).path()).is_err());
        let f = write(&[9, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]);
        let file = File::open(f.path()).unwrap();
        let mut r = Reader {
            inner: BufReader::new(file),
            end: 12,
        };
        assert!(r.value(9, false, 0).is_err());
    }
}
