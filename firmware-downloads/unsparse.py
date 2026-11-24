import struct,sys
with open(sys.argv[1],'rb') as src,open(sys.argv[2],'wb') as dst:
 magic,major,minor,fh,ch,bs,blocks,n,crc=struct.unpack('<I4H4I',src.read(28))
 assert magic==0xed26ff3a and major==1
 src.seek(fh)
 for _ in range(n):
  t,_,b,size=struct.unpack('<2H2I',src.read(12));src.read(ch-12)
  length=b*bs; payload=size-ch
  if t==0xcac1:
   assert payload==length
   while length:
    d=src.read(min(length,1024*1024));assert d;dst.write(d);length-=len(d)
  elif t==0xcac2:
   assert payload==4
   pattern=src.read(4);chunk=pattern*(bs//4)
   for j in range(b):dst.write(chunk)
  elif t==0xcac3:
   assert payload==0;dst.seek(length,1)
  elif t==0xcac4:src.read(payload)
  else:raise ValueError(t)
 assert dst.tell()==blocks*bs
 dst.truncate()
