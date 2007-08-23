{- | This implements BootString en- and decoding, the foundation of Punycode
 -}
module Data.Encoding.BootString
	(BootString(..)
	,punycode) where

import Data.Encoding.Base
import Data.ByteString.Char8 (pack,unpack)
import Data.List (unfoldr,partition)
import Data.Char (ord,chr)

data BootString = BootString
	{base :: Int
	,tmin :: Int
	,tmax :: Int
	,skew :: Int
	,damp :: Int
	,init_bias :: Int
	,init_n    :: Int
	}

punycode :: BootString
punycode = BootString
	{base = 36
	,tmin = 1
	,tmax = 26
	,skew = 38
	,damp = 700
	,init_bias = 72
	,init_n    = 0x80
	}

punyValue :: Char -> Int
punyValue c
	| n <  0x30 = norep
	| n <= 0x39 = n-0x30+26
	| n <  0x41 = norep
	| n <= 0x5A = n-0x41
	| n <  0x61 = norep
	| n <= 0x7A = n-0x61
	| otherwise = norep
	where
	n = ord c
	norep = error $ "No puny representation for "++show c

punyChar :: Int -> Char
punyChar c
	| c < 0  = norep
	| c < 26 = chr $ 0x61+c
	| c < 36 = chr $ 0x30+c-26
	| otherwise = norep
	where
	norep = error $ "No char representation for puny value "++show c

threshold :: BootString -> Int -> Int -> Int
threshold bs bias pos
	| r > tmax bs = tmax bs
	| r < tmin bs = tmin bs
	where
	r = (base bs)*(pos+1)-bias

adapt :: BootString -> Int -> Int -> Bool -> Int
adapt bs delta numpoints firsttime = let
	delta1 = if firsttime
		then delta `div` (damp bs)
		else delta `div` 2
	delta2 = delta1 + (delta1 `div` numpoints)
	(rd,rk) = head
		$ filter ((<=((base bs - tmin bs) * (tmax bs)) `div` 2).fst)
		$ iterate (\(d,k) -> (d `div` (base bs - tmin bs),k+1)) (delta2,0)
	in rk + (((base bs - tmin bs +1) * rd) `div` (rd + skew bs))

decodeValue :: BootString -> Int -> Int -> Int -> Int -> [Int] -> (Int,[Int])
decodeValue bs bias i k w (x:xs) = let
	ni = i + x*w
	t  = if k <= bias + (tmin bs)
		then tmin bs
		else (if k >= bias + (tmax bs)
			then tmax bs
			else k-bias)
	in if x < t
		then (ni,xs)
		else decodeValue bs bias ni (k+base bs) (w*(base bs - t)) xs

decodeValues :: BootString -> Int -> [Int] -> [(Char,Int)]
decodeValues bs len xs = decodeValues' bs (init_n bs) 0 (init_bias bs) len xs

decodeValues' :: BootString -> Int -> Int -> Int -> Int -> [Int] -> [(Char,Int)]
decodeValues' bs n i bias len [] = []
decodeValues' bs n i bias len xs = let
	(ni,rst) = decodeValue bs bias i (base bs) 1 xs
	(dn,nni) = ni `divMod` (len+1)
	nn       = n + dn
	in (chr $ nn,nni):decodeValues' bs nn (nni+1)
		(adapt bs (ni-i) (len+1) (i==0)) (len+1) rst

insertDeltas :: [(Char,Int)] -> String -> String
insertDeltas [] str     = str
insertDeltas ((c,p):xs) str = let
	(l,r) = splitAt p str
	in insertDeltas xs (l++[c]++r)

punyDecode :: String -> String -> String
punyDecode base ext = insertDeltas (decodeValues punycode (length base) (map punyValue ext)) base

encodeValue :: BootString -> Int -> Int -> Int -> Int -> [Int]
encodeValue bs bias delta n c = unfoldr (\(q,k,out) -> let
		t = if k <= bias + tmin bs
			then tmin bs
			else (if k >= bias + tmax bs
				then tmax bs
				else k - bias)
		(nq,dc) = (q-t) `divMod` (base bs - t)
		in if out
			then Nothing
			else (if q < t
				then Just (q,(q,k+base bs,True))
				else Just (t + dc,(nq,k+base bs,False)))
		) (delta,base bs,False)

encodeValues' :: BootString -> Int -> Int -> Int -> Int -> Int -> [Int] -> (Int,Int,Int,[Int])
encodeValues' _  _ h bias delta _ []     = (delta,h,bias,[])
encodeValues' bs b h bias delta n (c:cs) = case compare c n of
	LT -> encodeValues' bs b h bias (delta+1) n cs
	GT -> encodeValues' bs b h bias delta n cs
	EQ -> let
		(ndelta,nh,nbias,rest) = encodeValues' bs b (h+1) (adapt bs delta (h+1) (h==b)) 0 n cs
		xs = encodeValue bs bias delta n c
		in (ndelta,nh,nbias,xs++rest)

encodeValues :: BootString -> Int -> Int -> Int -> Int -> Int -> Int -> [Int] -> [Int]
encodeValues bs b l h bias delta n cps
	| h == l = []
	| otherwise = outp++encodeValues bs b l nh nbias (ndelta+1) (m+1) cps
	where
	m = minimum (filter (>=n) cps)
	(ndelta,nh,nbias,outp) = encodeValues' bs b h bias (delta + (m - n)*(h + 1)) m cps

instance Encoding BootString where
	encode bs str = let
		(base,nbase) = partition (\c -> ord c < init_n bs) str
		b = length base
		res = map punyChar $
			encodeValues bs b (length str) b (init_bias bs) 0 (init_n bs) (map ord str)
		in pack $ if null base
			then res
			else base++"-"++res
	decode bs str = case break (=='-') (unpack str) of
		(base,'-':nbase) -> punyDecode base nbase
		(nbase,"") -> punyDecode "" nbase