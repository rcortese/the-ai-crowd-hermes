import hashlib, io, json, pathlib, sys, tarfile, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]; sys.path.insert(0,str(ROOT/'ops'/'release'))
import hermes_base_v3 as c
COMMIT="918b36785653ec291806558e30b302b8cad10777"; TREE="817966c265522f8a7ae07473284451e17f1e683a"; SHA="8a26e82ce96b4b5429d0321e19ddb0b01bed9d5925ab2a0ecc89e9201bfe6aee"
def lock(): return {"schema":c.LOCK_SCHEMA,"source":{"git_dir":"/g","work_tree":"/w","commit":COMMIT,"tree":TREE,"archive":{"format":"tar","prefix":"hermes-agent/","sha256":SHA,"bytes":1}},"image":{"repository":"the-ai-crowd/hermes-base","pre_normalization_tag":"the-ai-crowd/hermes-base:pre-918b36785653","final_tag":None,"final_image_id":None},"receipt":None}
def receipt():
 x={"schema":c.RECEIPT_SCHEMA,"source_commit":COMMIT,"source_tree":TREE,"archive_sha256":SHA,"archive_bytes":1,"pre_normalization_tag":lock()["image"]["pre_normalization_tag"],"pre_normalization_image_id":"sha256:"+"a"*64,"final_tag":"the-ai-crowd/hermes-base:final","final_image_id":"sha256:"+"b"*64,"normalized_config":{"Env":["A=B"],"Volumes":{} }}; x["normalized_config_sha256"]=c.config_sha256(x["normalized_config"]); return x
def add(t,name,body):
 b=body if isinstance(body,bytes) else json.dumps(body).encode(); i=tarfile.TarInfo(name); i.size=len(b); t.addfile(i,io.BytesIO(b))
def image(path,volumes={"/opt/data":{}}, duplicate=False, malformed=False):
 with tarfile.open(path,"w") as t:
  add(t,"manifest.json", [{"Config":"cfg.json","RepoTags":["old:tag"],"Layers":["layer"]}]); add(t,"cfg.json", b"bad" if malformed else {"config":{"Volumes":volumes,"Env":["A=B"]},"other":1}); add(t,"layer",b"unchanged")
  if duplicate: add(t,"layer",b"again")
class Contract(unittest.TestCase):
 def test_lock_and_archive(self):
  self.assertEqual(c.validate_lock(lock())["source"]["commit"],COMMIT)
  x=lock(); x["image"]["pre_normalization_tag"]="candidate"
  with self.assertRaisesRegex(ValueError,"repository-qualified"): c.validate_lock(x)
  x=lock(); x["source"]["archive"].update(bytes=3,sha256=hashlib.sha256(b"abc").hexdigest()); c.verify_archive_stream(x,io.BytesIO(b"abc"))
 def test_tar_sole_delta(self):
  with tempfile.TemporaryDirectory() as d:
   a,b=pathlib.Path(d)/"a.tar",pathlib.Path(d)/"b.tar"; image(a); c.normalize_image_tar(a,b,"the-ai-crowd/hermes-base:final")
   with tarfile.open(a) as x,tarfile.open(b) as y:
    self.assertEqual(x.getnames(),y.getnames()); self.assertEqual(x.extractfile("layer").read(),y.extractfile("layer").read()); self.assertEqual(json.load(y.extractfile("cfg.json"))["config"]["Volumes"],{}); self.assertEqual(json.load(y.extractfile("manifest.json"))[0]["RepoTags"],["the-ai-crowd/hermes-base:final"])
 def test_tar_rejects_residual_malformed_duplicate(self):
  with tempfile.TemporaryDirectory() as d:
   for n,k,err in (("r",False,"residual"),("m",False,"malformed"),("d",True,"duplicate")):
    a,b=pathlib.Path(d)/(n+".tar"),pathlib.Path(d)/(n+"o.tar"); image(a,{"/opt/data":{},"/tmp":{}} if n=="r" else {"/opt/data":{}},k,n=="m")
    with self.assertRaisesRegex(ValueError,err): c.normalize_image_tar(a,b,"the-ai-crowd/hermes-base:final")
 def test_receipt_tag_and_projection_negatives(self):
  r=receipt(); self.assertEqual(c.verify_receipt(r,lock())["final_tag"],r["final_tag"])
  r=receipt(); r["final_tag"]="other/repo:x"
  with self.assertRaisesRegex(ValueError,"locked repository"): c.verify_receipt(r,lock())
  r=receipt(); r["normalized_config"]["Env"]=["A=C"]
  with self.assertRaisesRegex(ValueError,"does not match"): c.verify_receipt(r,lock())
  r=receipt(); r["normalized_config"]["Volumes"]={"/tmp":{}}; r["normalized_config_sha256"]=c.config_sha256(r["normalized_config"])
  with self.assertRaisesRegex(ValueError,"residual"): c.verify_receipt(r,lock())
if __name__=="__main__": unittest.main()
