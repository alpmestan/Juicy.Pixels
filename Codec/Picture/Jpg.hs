{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fspec-constr-count=5 #-}
-- | Module used for JPEG file loading and writing.
module Codec.Picture.Jpg( decodeJpeg, encodeJpegAtQuality, encodeJpeg ) where

import Control.Arrow( (>>>) )
import Control.Applicative( (<$>), (<*>))
import Control.Monad( when, replicateM, forM, forM_, foldM_, unless )
import Control.Monad.ST( ST, runST )
import Control.Monad.Trans( lift )
import qualified Control.Monad.Trans.State.Strict as S

import Data.List( find, foldl' )
import Data.Bits( (.|.), (.&.), shiftL, shiftR )
import Data.Int( Int16, Int32 )
import Data.Word(Word8, Word16, Word32)
import Data.Binary( Binary(..), encode )

import Data.Binary.Get( Get
                      , getWord8
                      , getWord16be
                      , getByteString
                      , skip
                      , bytesRead
                      )

import Data.Binary.Put( Put
                      , putWord8
                      , putWord16be
                      , putByteString
                      )

import Data.Maybe( fromJust )
import qualified Data.Vector as V
import Data.Vector.Unboxed( (!) )
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as M
-- import Data.Array.Unboxed( Array, UArray, elems, listArray, (!) )
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Foreign.Storable ( Storable )

import Codec.Picture.InternalHelper
import Codec.Picture.BitWriter
import Codec.Picture.Types
import Codec.Picture.Jpg.Types
import Codec.Picture.Jpg.DefaultTable
import Codec.Picture.Jpg.FastIdct
import Codec.Picture.Jpg.FastDct

--------------------------------------------------
----            Types
--------------------------------------------------
data JpgFrameKind =
      JpgBaselineDCTHuffman
    | JpgExtendedSequentialDCTHuffman
    | JpgProgressiveDCTHuffman
    | JpgLosslessHuffman
    | JpgDifferentialSequentialDCTHuffman
    | JpgDifferentialProgressiveDCTHuffman
    | JpgDifferentialLosslessHuffman
    | JpgExtendedSequentialArithmetic
    | JpgProgressiveDCTArithmetic
    | JpgLosslessArithmetic
    | JpgDifferentialSequentialDCTArithmetic
    | JpgDifferentialProgressiveDCTArithmetic
    | JpgDifferentialLosslessArithmetic
    | JpgQuantizationTable
    | JpgHuffmanTableMarker
    | JpgStartOfScan
    | JpgAppSegment Word8
    | JpgExtensionSegment Word8

    | JpgRestartInterval
    deriving (Eq, Show)

type HuffmanTreeInfo = HuffmanPackedTree

data JpgFrame =
      JpgAppFrame        !Word8 B.ByteString
    | JpgExtension       !Word8 B.ByteString
    | JpgQuantTable      ![JpgQuantTableSpec]
    | JpgHuffmanTable    ![(JpgHuffmanTableSpec, HuffmanTreeInfo)]
    | JpgScanBlob        !JpgScanHeader !B.ByteString
    | JpgScans           !JpgFrameKind !JpgFrameHeader
    | JpgIntervalRestart !Word16
    deriving Show

data JpgFrameHeader = JpgFrameHeader
    { jpgFrameHeaderLength   :: !Word16
    , jpgSamplePrecision     :: !Word8
    , jpgHeight              :: !Word16
    , jpgWidth               :: !Word16
    , jpgImageComponentCount :: !Word8
    , jpgComponents          :: ![JpgComponent]
    }
    deriving Show

instance SizeCalculable JpgFrameHeader where
    calculateSize hdr = 2 + 1 + 2 + 2 + 1 
                      + sum [calculateSize c | c <- jpgComponents hdr]

data JpgComponent = JpgComponent
    { componentIdentifier       :: !Word8
      -- | Stored with 4 bits
    , horizontalSamplingFactor  :: !Word8
      -- | Stored with 4 bits
    , verticalSamplingFactor    :: !Word8
    , quantizationTableDest     :: !Word8
    }
    deriving Show

instance SizeCalculable JpgComponent where
    calculateSize _ = 3

data JpgImage = JpgImage { jpgFrame :: [JpgFrame]}
    deriving Show

data JpgScanSpecification = JpgScanSpecification
    { componentSelector :: !Word8
      -- | Encoded as 4 bits
    , dcEntropyCodingTable :: !Word8
      -- | Encoded as 4 bits
    , acEntropyCodingTable :: !Word8

    }
    deriving Show

instance SizeCalculable JpgScanSpecification where
    calculateSize _ = 2

data JpgScanHeader = JpgScanHeader
    { scanLength :: !Word16
    , scanComponentCount :: !Word8
    , scans :: [JpgScanSpecification]

      -- | (begin, end)
    , spectralSelection    :: (Word8, Word8)

      -- | Encoded as 4 bits
    , successiveApproxHigh :: !Word8

      -- | Encoded as 4 bits
    , successiveApproxLow :: !Word8
    }
    deriving Show

instance SizeCalculable JpgScanHeader where
    calculateSize hdr = 2 + 1
                      + sum [calculateSize c | c <- scans hdr]
                      + 2
                      + 1
    
data JpgQuantTableSpec = JpgQuantTableSpec
    { -- | Stored on 4 bits
      quantPrecision     :: !Word8

      -- | Stored on 4 bits
    , quantDestination   :: !Word8

    , quantTable         :: MacroBlock Int16
    }
    deriving Show

-- | Type introduced only to avoid some typeclass overlapping
-- problem
newtype TableList a = TableList [a]

class SizeCalculable a where
    calculateSize :: a -> Int

instance (SizeCalculable a, Binary a) => Binary (TableList a) where
    put (TableList lst) = do
        putWord16be . fromIntegral $ sum [calculateSize table | table <- lst] + 2
        mapM_ put lst

    get = TableList <$> (getWord16be >>= \s -> innerParse (fromIntegral s - 2))
      where innerParse :: Int -> Get [a]
            innerParse 0    = return []
            innerParse size = do
                onStart <- fromIntegral <$> bytesRead
                table <- get
                onEnd <- fromIntegral <$> bytesRead
                (table :) <$> innerParse (size - (onEnd - onStart))

instance SizeCalculable JpgQuantTableSpec where
    calculateSize table =
        1 + (fromIntegral (quantPrecision table) + 1) * 64

instance Binary JpgQuantTableSpec where
    put table = do
        let precision = quantPrecision table
        put4BitsOfEach precision (quantDestination table)
        forM_ (VS.toList $ quantTable table) $ \coeff ->
            if precision == 0 then putWord8 $ fromIntegral coeff
                             else putWord16be $ fromIntegral coeff

    get = do
        (precision, dest) <- get4BitOfEach
        coeffs <- replicateM 64 $ if precision == 0
                then fromIntegral <$> getWord8
                else fromIntegral <$> getWord16be
        return JpgQuantTableSpec
            { quantPrecision = precision
            , quantDestination = dest
            , quantTable = VS.fromListN 64 coeffs
            }

data JpgHuffmanTableSpec = JpgHuffmanTableSpec
    { -- | 0 : DC, 1 : AC, stored on 4 bits
      huffmanTableClass       :: !DctComponent
      -- | Stored on 4 bits
    , huffmanTableDest        :: !Word8

    , huffSizes :: !(VU.Vector Word8)
    , huffCodes :: !(V.Vector (VU.Vector Word8))
    }
    deriving Show

buildPackedHuffmanTree :: V.Vector (VU.Vector Word8) -> HuffmanTree
buildPackedHuffmanTree = buildHuffmanTree . map VU.toList . V.toList

huffmanPackedDecode :: HuffmanPackedTree -> BoolReader s Word8
huffmanPackedDecode table = getNextBitJpg >>= aux 0
  where aux idx b | (v .&. 0x8000) /= 0 = return 0
                  | (v .&. 0x4000) /= 0 = return . fromIntegral $ v .&. 0xFF
                  | otherwise = getNextBitJpg >>= aux v
          where tableIndex | b = idx + 1
                           | otherwise = idx
                v = table `VS.unsafeIndex` fromIntegral tableIndex

--------------------------------------------------
----            Serialization instances
--------------------------------------------------
commonMarkerFirstByte :: Word8
commonMarkerFirstByte = 0xFF

checkMarker :: Word8 -> Word8 -> Get ()
checkMarker b1 b2 = do
    rb1 <- getWord8
    rb2 <- getWord8
    when (rb1 /= b1 || rb2 /= b2)
         (fail "Invalid marker used")

eatUntilCode :: Get ()
eatUntilCode = do
    code <- getWord8
    unless (code == 0xFF) eatUntilCode

instance SizeCalculable JpgHuffmanTableSpec where
    calculateSize table = 1 + 16 + sum [fromIntegral e | e <- VU.toList $ huffSizes table]

instance Binary JpgHuffmanTableSpec where
    put table = do
        let classVal = if huffmanTableClass table == DcComponent
                          then 0 else 1
        put4BitsOfEach classVal $ huffmanTableDest table
        mapM_ put . VU.toList $ huffSizes table
        forM_ [0 .. 15] $ \i ->
            when (huffSizes table ! i /= 0)
                 (let elements = VU.toList $ huffCodes table V.! i
                  in mapM_ put elements)

    get = do
        (huffClass, huffDest) <- get4BitOfEach
        sizes <- replicateM 16 getWord8
        codes <- forM sizes $ \s ->
            VU.replicateM (fromIntegral s) getWord8
        return JpgHuffmanTableSpec
            { huffmanTableClass =
                if huffClass == 0 then DcComponent else AcComponent
            , huffmanTableDest = huffDest
            , huffSizes = VU.fromListN 16 sizes
            , huffCodes = V.fromListN 16 codes
            }

instance Binary JpgImage where
    put (JpgImage { jpgFrame = frames }) =
        putWord8 0xFF >> putWord8 0xD8 >> mapM_ putFrame frames
            >> putWord8 0xFF >> putWord8 0xD9

    get = do
        let startOfImageMarker = 0xD8
            -- endOfImageMarker = 0xD9
        checkMarker commonMarkerFirstByte startOfImageMarker
        eatUntilCode
        frames <- parseFrames
        {-checkMarker commonMarkerFirstByte endOfImageMarker-}
        return JpgImage { jpgFrame = frames }

takeCurrentFrame :: Get B.ByteString
takeCurrentFrame = do
    size <- getWord16be
    getByteString (fromIntegral size - 2)

putFrame :: JpgFrame -> Put
putFrame (JpgAppFrame appCode str) =
    put (JpgAppSegment appCode) >> putWord16be (fromIntegral $ B.length str) >> put str
putFrame (JpgExtension appCode str) =
    put (JpgExtensionSegment appCode) >> putWord16be (fromIntegral $ B.length str) >> put str
putFrame (JpgQuantTable tables) =
    put JpgQuantizationTable >> put (TableList tables)
putFrame (JpgHuffmanTable tables) =
    put JpgHuffmanTableMarker >> put (TableList $ map fst tables)
putFrame (JpgIntervalRestart size) =
    put JpgRestartInterval >> put (RestartInterval size)
putFrame (JpgScanBlob hdr blob) =
    put JpgStartOfScan >> put hdr >> putByteString blob
putFrame (JpgScans kind hdr) =
    put kind >> put hdr

parseFrames :: Get [JpgFrame]
parseFrames = do
    kind <- get
    let parseNextFrame = do
            word <- getWord8
            when (word /= 0xFF) $ do
                readedData <- bytesRead
                fail $ "Invalid Frame marker (" ++ show word
                     ++ ", bytes read : " ++ show readedData ++ ")"
            parseFrames

    case kind of
        JpgAppSegment c ->
            (\frm lst -> JpgAppFrame c frm : lst) <$> takeCurrentFrame <*> parseNextFrame
        JpgExtensionSegment c ->
            (\frm lst -> JpgExtension c frm : lst) <$> takeCurrentFrame <*> parseNextFrame
        JpgQuantizationTable ->
            (\(TableList quants) lst -> JpgQuantTable quants : lst) <$> get <*> parseNextFrame
        JpgRestartInterval ->
            (\(RestartInterval i) lst -> JpgIntervalRestart i : lst) <$> get <*> parseNextFrame
        JpgHuffmanTableMarker ->
            (\(TableList huffTables) lst ->
                    JpgHuffmanTable [(t, packHuffmanTree . buildPackedHuffmanTree $ huffCodes t) | t <- huffTables] : lst)
                    <$> get <*> parseNextFrame
        JpgStartOfScan ->
            (\frm imgData -> [JpgScanBlob frm imgData])
                            <$> get <*> getRemainingBytes

        _ -> (\hdr lst -> JpgScans kind hdr : lst) <$> get <*> parseNextFrame

secondStartOfFrameByteOfKind :: JpgFrameKind -> Word8
secondStartOfFrameByteOfKind JpgBaselineDCTHuffman = 0xC0
secondStartOfFrameByteOfKind JpgExtendedSequentialDCTHuffman = 0xC1
secondStartOfFrameByteOfKind JpgProgressiveDCTHuffman = 0xC2
secondStartOfFrameByteOfKind JpgLosslessHuffman = 0xC3
secondStartOfFrameByteOfKind JpgDifferentialSequentialDCTHuffman = 0xC5
secondStartOfFrameByteOfKind JpgDifferentialProgressiveDCTHuffman = 0xC6
secondStartOfFrameByteOfKind JpgDifferentialLosslessHuffman = 0xC7
secondStartOfFrameByteOfKind JpgExtendedSequentialArithmetic = 0xC9
secondStartOfFrameByteOfKind JpgProgressiveDCTArithmetic = 0xCA
secondStartOfFrameByteOfKind JpgLosslessArithmetic = 0xCB
secondStartOfFrameByteOfKind JpgHuffmanTableMarker = 0xC4
secondStartOfFrameByteOfKind JpgDifferentialSequentialDCTArithmetic = 0xCD
secondStartOfFrameByteOfKind JpgDifferentialProgressiveDCTArithmetic = 0xCE
secondStartOfFrameByteOfKind JpgDifferentialLosslessArithmetic = 0xCF
secondStartOfFrameByteOfKind JpgQuantizationTable = 0xDB
secondStartOfFrameByteOfKind JpgStartOfScan = 0xDA
secondStartOfFrameByteOfKind JpgRestartInterval = 0xDD
secondStartOfFrameByteOfKind (JpgAppSegment a) = a
secondStartOfFrameByteOfKind (JpgExtensionSegment a) = a

instance Binary JpgFrameKind where
    put v = putWord8 0xFF >> put (secondStartOfFrameByteOfKind v)
    get = do
        -- no lookahead :(
        {-word <- getWord8-}
        word2 <- getWord8
        return $ case word2 of
            0xC0 -> JpgBaselineDCTHuffman
            0xC1 -> JpgExtendedSequentialDCTHuffman
            0xC2 -> JpgProgressiveDCTHuffman
            0xC3 -> JpgLosslessHuffman
            0xC4 -> JpgHuffmanTableMarker
            0xC5 -> JpgDifferentialSequentialDCTHuffman
            0xC6 -> JpgDifferentialProgressiveDCTHuffman
            0xC7 -> JpgDifferentialLosslessHuffman
            0xC9 -> JpgExtendedSequentialArithmetic
            0xCA -> JpgProgressiveDCTArithmetic
            0xCB -> JpgLosslessArithmetic
            0xCD -> JpgDifferentialSequentialDCTArithmetic
            0xCE -> JpgDifferentialProgressiveDCTArithmetic
            0xCF -> JpgDifferentialLosslessArithmetic
            0xDA -> JpgStartOfScan
            0xDB -> JpgQuantizationTable
            0xDD -> JpgRestartInterval
            a | a >= 0xF0 -> JpgExtensionSegment a
              | a >= 0xE0 -> JpgAppSegment a
              | otherwise -> error ("Invalid frame marker (" ++ show a ++ ")")

put4BitsOfEach :: Word8 -> Word8 -> Put
put4BitsOfEach a b = put $ (a `shiftL` 4) .|. b

get4BitOfEach :: Get (Word8, Word8)
get4BitOfEach = do
    val <- get
    return ((val `shiftR` 4) .&. 0xF, val .&. 0xF)

newtype RestartInterval = RestartInterval Word16

instance Binary RestartInterval where
    put (RestartInterval i) = putWord16be 4 >> putWord16be i
    get = do
        size <- getWord16be
        when (size /= 4) (fail "Invalid jpeg restart interval size")
        RestartInterval <$> getWord16be

instance Binary JpgComponent where
    get = do
        ident <- getWord8
        (horiz, vert) <- get4BitOfEach
        quantTableIndex <- getWord8
        return JpgComponent
            { componentIdentifier = ident
            , horizontalSamplingFactor = horiz
            , verticalSamplingFactor = vert
            , quantizationTableDest = quantTableIndex
            }
    put v = do
        put $ componentIdentifier v
        put4BitsOfEach (horizontalSamplingFactor v) $ verticalSamplingFactor v
        put $ quantizationTableDest v

instance Binary JpgFrameHeader where
    get = do
        beginOffset <- fromIntegral <$> bytesRead
        frmHLength <- getWord16be
        samplePrec <- getWord8
        h <- getWord16be
        w <- getWord16be
        compCount <- getWord8
        components <- replicateM (fromIntegral compCount) get
        endOffset <- fromIntegral <$> bytesRead
        when (beginOffset - endOffset < fromIntegral frmHLength)
             (skip $ fromIntegral frmHLength - (endOffset - beginOffset))
        return JpgFrameHeader
            { jpgFrameHeaderLength = frmHLength
            , jpgSamplePrecision = samplePrec
            , jpgHeight = h
            , jpgWidth = w
            , jpgImageComponentCount = compCount
            , jpgComponents = components
            }

    put v = do
        putWord16be $ jpgFrameHeaderLength v
        putWord8    $ jpgSamplePrecision v
        putWord16be $ jpgHeight v
        putWord16be $ jpgWidth v
        putWord8    $ jpgImageComponentCount v
        mapM_ put   $ jpgComponents v

instance Binary JpgScanSpecification where
    put v = do
        put $ componentSelector v
        put4BitsOfEach (dcEntropyCodingTable v) $ acEntropyCodingTable v

    get = do
        compSel <- get
        (dc, ac) <- get4BitOfEach
        return JpgScanSpecification {
            componentSelector = compSel
          , dcEntropyCodingTable = dc
          , acEntropyCodingTable = ac
          }

instance Binary JpgScanHeader where
    get = do
        thisScanLength <- getWord16be
        compCount <- getWord8
        comp <- replicateM (fromIntegral compCount) get
        specBeg <- get
        specEnd <- get
        (approxHigh, approxLow) <- get4BitOfEach
        return JpgScanHeader {
            scanLength = thisScanLength,
            scanComponentCount = compCount,
            scans = comp,
            spectralSelection = (specBeg, specEnd),
            successiveApproxHigh = approxHigh,
            successiveApproxLow = approxLow
        }

    put v = do
        putWord16be $ scanLength v
        putWord8 $ scanComponentCount v
        mapM_ put $ scans v
        putWord8 . fst $ spectralSelection v
        putWord8 . snd $ spectralSelection v
        put4BitsOfEach (successiveApproxHigh v) $ successiveApproxLow v

quantize :: MacroBlock Int16 -> MutableMacroBlock s Int32
         -> ST s (MutableMacroBlock s Int32)
quantize table block = update 0
  where update 64 = return block
        update idx = do
            val <- block `M.unsafeRead` idx
            let q = fromIntegral (table `VS.unsafeIndex` idx)
                finalValue = (val + (q `div` 2)) `quot` q -- rounded integer division
            (block `M.unsafeWrite` idx) finalValue
            update $ idx + 1

-- | Apply a quantization matrix to a macroblock
{-# INLINE deQuantize #-}
deQuantize :: MacroBlock Int16 -> MutableMacroBlock s Int16
           -> ST s (MutableMacroBlock s Int16)
deQuantize table block = update 0
    where update 64 = return block
          update i = do
              val <- block `M.unsafeRead` i
              let finalValue = val * (table `VS.unsafeIndex` i)
              (block `M.unsafeWrite` i) finalValue
              update $ i + 1

inverseDirectCosineTransform :: MutableMacroBlock s Int16
                             -> ST s (MutableMacroBlock s Int16)
inverseDirectCosineTransform mBlock =
    fastIdct mBlock >>= mutableLevelShift

zigZagOrder :: MacroBlock Word8
zigZagOrder = makeMacroBlock $ concat
    [[ 0, 1, 5, 6,14,15,27,28]
    ,[ 2, 4, 7,13,16,26,29,42]
    ,[ 3, 8,12,17,25,30,41,43]
    ,[ 9,11,18,24,31,40,44,53]
    ,[10,19,23,32,39,45,52,54]
    ,[20,22,33,38,46,51,55,60]
    ,[21,34,37,47,50,56,59,61]
    ,[35,36,48,49,57,58,62,63]
    ]

zigZagReorderForwardv :: (Storable a, Num a) => VS.Vector a -> VS.Vector a
zigZagReorderForwardv vec = runST $ do
    v <- M.new 64
    mv <- VS.thaw vec
    zigZagReorderForward v mv >>= VS.freeze

zigZagReorderForward :: (Storable a, Num a)
                     => MutableMacroBlock s a
                     -> MutableMacroBlock s a
                     -> ST s (MutableMacroBlock s a)
zigZagReorderForward zigzaged block = do
    let update i =  do
            let idx = zigZagOrder `VS.unsafeIndex` i
            v <- block `M.unsafeRead` fromIntegral i
            (zigzaged `M.unsafeWrite` fromIntegral idx) v

        reorder 64 = return ()
        reorder i  = update i >> reorder (i + 1)

    reorder (0 :: Int)
    return zigzaged

zigZagReorder :: MutableMacroBlock s Int16 -> MutableMacroBlock s Int16
              -> ST s (MutableMacroBlock s Int16)
zigZagReorder zigzaged block = do
    let update i =  do
            let idx = zigZagOrder `VS.unsafeIndex` i
            v <- block `M.unsafeRead` fromIntegral idx
            (zigzaged `M.unsafeWrite` i) v

        reorder 63 = update 63
        reorder i  = update i >> reorder (i + 1)

    reorder (0 :: Int)
    return zigzaged


-- | This is one of the most important function of the decoding,
-- it form the barebone decoding pipeline for macroblock. It's all
-- there is to know for macro block transformation
decodeMacroBlock :: MacroBlock DctCoefficients
                 -> MutableMacroBlock s Int16
                 -> MutableMacroBlock s Int16
                 -> ST s (MutableMacroBlock s Int16)
decodeMacroBlock quantizationTable zigZagBlock block =
    deQuantize quantizationTable block >>= zigZagReorder zigZagBlock
                                       >>= inverseDirectCosineTransform

packInt :: [Bool] -> Int32
packInt = foldl' bitStep 0
    where bitStep acc True = (acc `shiftL` 1) + 1
          bitStep acc False = acc `shiftL` 1

-- | Unpack an int of the given size encoded from MSB to LSB.
unpackInt :: Int32 -> BoolReader s Int32
unpackInt bitCount = packInt <$> replicateM (fromIntegral bitCount) getNextBitJpg

powerOf :: Int32 -> Word32
powerOf 0 = 0
powerOf n = limit 1 0
    where val = abs n
          limit range i | val < range = i
          limit range i = limit (2 * range) (i + 1)

encodeInt :: Word32 -> Int32 -> BoolWriter s ()
encodeInt ssss n | n > 0 = writeBits (fromIntegral n) (fromIntegral ssss)
encodeInt ssss n         = writeBits (fromIntegral $ n - 1) (fromIntegral ssss)

{-# INLINE decodeInt #-}
decodeInt :: Int32 -> BoolReader s Int32
decodeInt ssss = do
    signBit <- getNextBitJpg
    let dataRange = 1 `shiftL` fromIntegral (ssss - 1)
        leftBitCount = ssss - 1
    -- First following bits store the sign of the coefficient, and counted in
    -- SSSS, so the bit count for the int, is ssss - 1
    if signBit
       then (\w -> dataRange + fromIntegral w) <$> unpackInt leftBitCount
       else (\w -> 1 - dataRange * 2 + fromIntegral w) <$> unpackInt leftBitCount

dcCoefficientDecode :: HuffmanTreeInfo
                    -> BoolReader s DcCoefficient
dcCoefficientDecode dcTree = do
    ssss <- huffmanPackedDecode dcTree
    if ssss == 0
       then return 0
       else fromIntegral <$> decodeInt (fromIntegral ssss)

-- | Assume the macro block is initialized with zeroes
acCoefficientsDecode :: HuffmanTreeInfo -> MutableMacroBlock s Int16
                     -> BoolReader s (MutableMacroBlock s Int16)
acCoefficientsDecode acTree mutableBlock = parseAcCoefficient 1 >> return mutableBlock
  where parseAcCoefficient n | n >= 64 = return ()
                             | otherwise = do
            rrrrssss <- huffmanPackedDecode acTree
            let rrrr = fromIntegral $ (rrrrssss `shiftR` 4) .&. 0xF
                ssss =  rrrrssss .&. 0xF
            case (rrrr, ssss) of
                (  0, 0) -> return ()
                (0xF, 0) -> parseAcCoefficient (n + 16)
                _        -> do
                    decoded <- fromIntegral <$> decodeInt (fromIntegral ssss)
                    lift $ (mutableBlock `M.unsafeWrite` (n + rrrr)) decoded
                    parseAcCoefficient (n + rrrr + 1)

-- | Decompress a macroblock from a bitstream given the current configuration
-- from the frame.
decompressMacroBlock :: HuffmanTreeInfo     -- ^ Tree used for DC coefficient
                     -> HuffmanTreeInfo     -- ^ Tree used for Ac coefficient
                     -> MacroBlock Int16    -- ^ Current quantization table
                     -> MutableMacroBlock s Int16    -- ^ A zigzag table, to avoid allocation
                     -> DcCoefficient       -- ^ Previous dc value
                     -> BoolReader s (DcCoefficient, MutableMacroBlock s Int16)
decompressMacroBlock dcTree acTree quantizationTable zigzagBlock previousDc = do
    dcDeltaCoefficient <- dcCoefficientDecode dcTree
    block <- lift createEmptyMutableMacroBlock
    let neoDcCoefficient = previousDc + dcDeltaCoefficient
    lift $ (block `M.unsafeWrite` 0) neoDcCoefficient
    fullBlock <- acCoefficientsDecode acTree block
    decodedBlock <- lift $ decodeMacroBlock quantizationTable zigzagBlock fullBlock
    return (neoDcCoefficient, decodedBlock)

gatherQuantTables :: JpgImage -> [JpgQuantTableSpec]
gatherQuantTables img = concat [t | JpgQuantTable t <- jpgFrame img]

gatherHuffmanTables :: JpgImage -> [(JpgHuffmanTableSpec, HuffmanTreeInfo)]
gatherHuffmanTables img = concat [lst | JpgHuffmanTable lst <- jpgFrame img]

gatherScanInfo :: JpgImage -> (JpgFrameKind, JpgFrameHeader)
gatherScanInfo img = fromJust $ unScan <$> find scanDesc (jpgFrame img)
    where scanDesc (JpgScans _ _) = True
          scanDesc _ = False

          unScan (JpgScans a b) = (a,b)
          unScan _ = error "If this can happen, the JPEG image is ill-formed"

pixelClamp :: Int16 -> Word8
pixelClamp n = fromIntegral . min 255 $ max 0 n

-- | Given a size coefficient (how much a pixel span horizontally
-- and vertically), the position of the macroblock, return a list
-- of indices and value to be stored in an array (like the final
-- image)
unpackMacroBlock :: Int    -- ^ Component count
                 -> Int    -- ^ Component index
                 -> Int -- ^ Width coefficient
                 -> Int -- ^ Height coefficient
                 -> Int -- ^ x
                 -> Int -- ^ y
                 -> MutableImage s PixelYCbCr8
                 -> MutableMacroBlock s Int16
                 -> ST s ()
    -- Simple case, a macroblock value => a pixel
unpackMacroBlock compCount compIdx  wCoeff hCoeff x y 
                 (MutableImage { mutableImageWidth = imgWidth,
                                 mutableImageHeight = imgHeight, mutableImageData = img })
                 block | x >= 0 && y >= 0 && (x + 1) * 8 < imgWidth && (y + 1) * 8 < imgHeight = blockVert 0
  where verticalWriteIncrement = imgWidth * compCount
        horizontalWriteIncrement = imgWidth * compCount

        blockVert j | j >= 8 = return ()
        blockVert j = blockHoriz 0
          where yBase = (j + y * 8) * hCoeff 
                blockHoriz i | i >= 8 = blockVert $ j + 1
                blockHoriz i = (pixelClamp <$> (block `M.unsafeRead` (i + j * 8))) >>= horizDup 0
                  where xBase = (i + x * 8) * wCoeff
                        horizDup wDup _ | wDup >= wCoeff = blockHoriz $ i + 1
                        horizDup wDup compVal = vertDup 0
                          where vertDup hDup | hDup >= hCoeff = horizDup (wDup + 1) compVal
                                vertDup hDup = do
                                  let xPos = xBase + wDup
                                      yPos = yBase + hDup
                                  let mutableIdx = (xPos + yPos * imgWidth) * compCount + compIdx
                                  (img `M.unsafeWrite` mutableIdx) compVal
                                  vertDup $ hDup + 1

unpackMacroBlock compCount compIdx  wCoeff hCoeff x y 
                 (MutableImage { mutableImageWidth = imgWidth,
                                 mutableImageHeight = imgHeight, mutableImageData = img })
                 block = blockVert 0
  where verticalWriteIncrement = imgWidth * compCount
        horizontalWriteIncrement = imgWidth * compCount

        blockVert j | j >= 8 = return ()
        blockVert j = blockHoriz 0
          where yBase = (j + y * 8) * hCoeff 
                blockHoriz i | i >= 8 = blockVert $ j + 1
                blockHoriz i = (pixelClamp <$> (block `M.unsafeRead` (i + j * 8))) >>= horizDup 0
                  where xBase = (i + x * 8) * wCoeff
                        horizDup wDup _ | wDup >= wCoeff = blockHoriz $ i + 1
                        horizDup wDup compVal = vertDup 0
                          where vertDup hDup | hDup >= hCoeff = horizDup (wDup + 1) compVal
                                vertDup hDup = do
                                  let xPos = xBase + wDup
                                      yPos = yBase + hDup
                                  when (0 <= xPos && xPos < imgWidth && 0 <= yPos && yPos < imgHeight)
                                       (do let mutableIdx = (xPos + yPos * imgWidth) * compCount + compIdx
                                           (img `M.unsafeWrite` mutableIdx) compVal)

                                  vertDup $ hDup + 1

-- | Type only used to make clear what kind of integer we are carrying
-- Might be transformed into newtype in the future
type DcCoefficient = Int16

-- | Same as for DcCoefficient, to provide nicer type signatures
type DctCoefficients = DcCoefficient

decodeRestartInterval :: BoolReader s Int32
decodeRestartInterval = return (-1) {-  do
  bits <- replicateM 8 getNextBitJpg
  if bits == replicate 8 True
     then do
         marker <- replicateM 8 getNextBitJpg
         return $ packInt marker
     else return (-1)
        -}

decodeImage :: JpgImage          
            -> Int -- ^ Component count
            -> MutableImage s PixelYCbCr8 -- ^ Result image to write into
            -> BoolReader s ()
decodeImage img compCount outImage = do
    zigZagArray <- lift $ createEmptyMutableMacroBlock
    dcArray <- lift (M.replicate compCount 0  :: ST s (M.STVector s DcCoefficient))

    let huffmans = gatherHuffmanTables img
        huffmanForComponent dcOrAc dest =
            head [t | (h,t) <- huffmans, huffmanTableClass h == dcOrAc
                                       , huffmanTableDest h == dest]
 
        mcuBeforeRestart = case [i | JpgIntervalRestart i <- jpgFrame img] of
            []    -> maxBound :: Int -- HUUUUUUGE value (enough to parse all MCU)
            (x:_) -> fromIntegral x
 
        quants = gatherQuantTables img
        quantForComponent dest =
            head [quantTable q | q <- quants, quantDestination q == dest]
 
        hdr = head [h | JpgScanBlob h _ <- jpgFrame img]
 
        (_, scanInfo) = gatherScanInfo img
        imgWidth = fromIntegral $ jpgWidth scanInfo
        imgHeight = fromIntegral $ jpgHeight scanInfo
 
        blockSizeOfDim fullDim maxBlockSize = block + (if rest /= 0 then 1 else 0)
                where (block, rest) = fullDim `divMod` maxBlockSize
 
        horizontalSamplings = [horiz | (horiz, _, _, _, _) <- componentsInfo]
 
        imgComponentCount = fromIntegral $ jpgImageComponentCount scanInfo
        isImageLumanOnly = imgComponentCount == 1
        maxHorizFactor | not isImageLumanOnly &&
                            not (allElementsEqual horizontalSamplings) = maximum horizontalSamplings
                       | otherwise = 1
 
        verticalSamplings = [vert | (_, vert, _, _, _) <- componentsInfo]
        maxVertFactor | not isImageLumanOnly &&
                            not (allElementsEqual verticalSamplings) = maximum verticalSamplings
                      | otherwise = 1
 
        horizontalBlockCount =
           blockSizeOfDim imgWidth $ fromIntegral (maxHorizFactor * 8)
 
        verticalBlockCount =
           blockSizeOfDim imgHeight $ fromIntegral (maxVertFactor * 8)

        fetchTablesForComponent component = (horizCount, vertCount, dcTree, acTree, qTable)
            where idx = componentIdentifier component
                  descr = head [c | c <- scans hdr, componentSelector c  == idx]
                  dcTree = -- packHuffmanTree .
                           huffmanForComponent DcComponent $ dcEntropyCodingTable descr
                  acTree = -- packHuffmanTree . 
                           huffmanForComponent AcComponent $ acEntropyCodingTable descr
                  qTable = quantForComponent $ if idx == 1 then 0 else 1
                  horizCount = if not isImageLumanOnly
                        then fromIntegral $ horizontalSamplingFactor component
                        else 1
                  vertCount = if not isImageLumanOnly
                        then fromIntegral $ verticalSamplingFactor component
                        else 1
 
        componentsInfo = map fetchTablesForComponent $ jpgComponents scanInfo

    let blockIndices = [(x,y) | y <- [0 ..   verticalBlockCount - 1]
                              , x <- [0 .. horizontalBlockCount - 1] ]
        blockBeforeRestart = mcuBeforeRestart

        folder f = foldM_ f blockBeforeRestart blockIndices

    folder (\resetCounter (x,y) -> do
        when (resetCounter == 0)
             (do forM_ [0.. compCount - 1] $
                     \c -> lift $ (dcArray `M.unsafeWrite` c) 0
                 byteAlignJpg
                 _restartCode <- decodeRestartInterval
                 -- if 0xD0 <= restartCode && restartCode <= 0xD7
                 return ())

{-
        mcus = [(compIdx, \x y writeImg zigzag dc -> do
                           (dcCoeff, block) <- decompressMacroBlock dcTree acTree qTable zigzag dc
                           lift $ unpacker (x * horizCount + xd) (y * vertCount + yd) writeImg block
                           return dcCoeff)
                     | (compIdx, (horizCount, vertCount, dcTree, acTree, qTable))
                                   <- zip [0..] componentsInfo
                     , let xScalingFactor = maxHorizFactor - horizCount + 1
                           yScalingFactor = maxVertFactor - vertCount + 1
                     , yd <- [0 .. vertCount - 1]
                     , xd <- [0 .. horizCount - 1]
                     , let unpacker = unpackMacroBlock imgComponentCount compIdx 
                                                    xScalingFactor yScalingFactor
                     ]

-}
        let comp _ [] = return ()
            comp compIdx ((horizCount, vertCount, dcTree, acTree, qTable):comp_rest) = liner 0
              where xScalingFactor = maxHorizFactor - horizCount + 1
                    yScalingFactor = maxVertFactor - vertCount + 1

                    liner yd | yd >= vertCount = comp (compIdx + 1) comp_rest
                    liner yd = columner 0
                      where columner xd | xd >= horizCount = liner (yd + 1)
                            columner xd = do
                                dc <- lift $ dcArray `M.unsafeRead` compIdx
                                (dcCoeff, block) <-
                                    decompressMacroBlock dcTree acTree qTable zigZagArray $ fromIntegral dc
                                lift $ unpackMacroBlock imgComponentCount compIdx xScalingFactor yScalingFactor
                                    (x * horizCount + xd) (y * vertCount + yd) outImage block
                                lift $ (dcArray `M.unsafeWrite` compIdx) dcCoeff
                                columner $ xd + 1
        comp 0 componentsInfo

{-
        forM_ (mcuDecoder decoder) $ \(comp, dataUnitDecoder) -> do
            dc <- lift $ dcArray `M.unsafeRead` comp
            dcCoeff <- dataUnitDecoder x y img zigZagArray $ fromIntegral dc
            lift $ (dcArray `M.unsafeWrite` comp) dcCoeff
            return ()
-}
        if resetCounter /= 0 then return $ resetCounter - 1
                                         -- we use blockBeforeRestart - 1 to count
                                         -- the current MCU
                            else return $ blockBeforeRestart - 1)

allElementsEqual :: (Eq a) => [a] -> Bool
allElementsEqual []     = True
allElementsEqual (x:xs) = all (== x) xs

-- | Try to decompress a jpeg file and decompress. The colorspace is still
-- YCbCr if you want to perform computation on the luma part. You can
-- convert it to RGB using 'convertImage' from the 'ColorSpaceConvertible'
-- typeclass.
--
-- This function can output the following pixel types :
--
--    * PixelY8
--
--    * PixelYCbCr8
--
decodeJpeg :: B.ByteString -> Either String DynamicImage
decodeJpeg file = case runGetStrict get file of
  Left err -> Left err
  Right img -> case compCount of
                 1 -> Right . ImageY8 $ Image imgWidth imgHeight pixelData
                 3 -> Right . ImageYCbCr8 $ Image imgWidth imgHeight pixelData
                 _ -> Left "Wrong component count"

      where (imgData:_) = [d | JpgScanBlob _kind d <- jpgFrame img]
            (_, scanInfo) = gatherScanInfo img
            compCount = length $ jpgComponents scanInfo

            imgWidth = fromIntegral $ jpgWidth scanInfo
            imgHeight = fromIntegral $ jpgHeight scanInfo

            imageSize = imgWidth * imgHeight * compCount

            pixelData = runST $ VS.unsafeFreeze =<< S.evalStateT (do
                resultImage <- lift $ M.replicate imageSize 0
                let wrapped = MutableImage imgWidth imgHeight resultImage
                setDecodedStringJpg imgData
                decodeImage img compCount wrapped
                return resultImage) (BoolState (-1) 0 B.empty)

extractBlock :: Image PixelYCbCr8       -- ^ Source image
             -> MutableMacroBlock s Int16      -- ^ Mutable block where to put extracted block
             -> Int                     -- ^ Plane
             -> Int                     -- ^ X sampling factor
             -> Int                     -- ^ Y sampling factor
             -> Int                     -- ^ Sample per pixel
             -> Int                     -- ^ Block x
             -> Int                     -- ^ Block y
             -> ST s (MutableMacroBlock s Int16)
extractBlock (Image { imageWidth = w, imageHeight = h, imageData = src })
             block 1 1 sampCount plane bx by | (bx * 8) + 7 < w && (by * 8) + 7 < h = do
    let baseReadIdx = (by * 8 * w) + bx * 8
    sequence_ [(block `M.unsafeWrite` (y * 8 + x)) val
                        | y <- [0 .. 7]
                        , let blockReadIdx = baseReadIdx + y * w
                        , x <- [0 .. 7]
                        , let val = fromIntegral $ src `VS.unsafeIndex` ((blockReadIdx + x) * sampCount + plane)
                        ]
    return block
extractBlock (Image { imageWidth = w, imageHeight = h, imageData = src })
             block sampWidth sampHeight sampCount plane bx by = do
    let accessPixel x y | x < w && y < h = let idx = (y * w + x) * sampCount + plane in src `VS.unsafeIndex` idx
                        | x >= w = accessPixel (w - 1) y
                        | otherwise = accessPixel x (h - 1)

        pixelPerCoeff = fromIntegral $ sampWidth * sampHeight

        blockVal x y = sum [fromIntegral $ accessPixel (xBase + dx) (yBase + dy)
                                | dy <- [0 .. sampHeight - 1]
                                , dx <- [0 .. sampWidth - 1] ] `div` pixelPerCoeff
            where xBase = blockXBegin + x * sampWidth
                  yBase = blockYBegin + y * sampHeight

        blockXBegin = bx * 8 * sampWidth
        blockYBegin = by * 8 * sampHeight

    sequence_ [(block `M.unsafeWrite` (y * 8 + x)) $ blockVal x y | y <- [0 .. 7], x <- [0 .. 7] ]
    return block

serializeMacroBlock :: HuffmanWriterCode -> HuffmanWriterCode
                    -> MutableMacroBlock s Int32
                    -> BoolWriter s ()
serializeMacroBlock dcCode acCode blk =
 lift (blk `M.unsafeRead` 0) >>= (fromIntegral >>> encodeDc) >> writeAcs (0, 1) >> return ()
  where writeAcs acc@(_, 63) =
            lift (blk `M.unsafeRead` 63) >>= (fromIntegral >>> encodeAcCoefs acc) >> return ()
        writeAcs acc@(_, i ) =
            lift (blk `M.unsafeRead`  i) >>= (fromIntegral >>> encodeAcCoefs acc) >>= writeAcs

        encodeDc n = writeBits (fromIntegral code) (fromIntegral bitCount)
                        >> when (ssss /= 0) (encodeInt ssss n)
            where ssss = powerOf $ fromIntegral n
                  (bitCount, code) = dcCode V.! fromIntegral ssss

        encodeAc 0         0 = writeBits (fromIntegral code) $ fromIntegral bitCount
            where (bitCount, code) = acCode V.! 0

        encodeAc zeroCount n | zeroCount >= 16 =
          writeBits (fromIntegral code) (fromIntegral bitCount) >>  encodeAc (zeroCount - 16) n
            where (bitCount, code) = acCode V.! 0xF0
        encodeAc zeroCount n =
          writeBits (fromIntegral code) (fromIntegral bitCount) >> encodeInt ssss n
            where rrrr = zeroCount `shiftL` 4
                  ssss = powerOf $ fromIntegral n
                  rrrrssss = rrrr .|. ssss
                  (bitCount, code) = acCode V.! fromIntegral rrrrssss

        encodeAcCoefs (            _, 63) 0 = encodeAc 0 0 >> return (0, 64)
        encodeAcCoefs (zeroRunLength,  i) 0 = return (zeroRunLength + 1, i + 1)
        encodeAcCoefs (zeroRunLength,  i) n =
            encodeAc zeroRunLength n >> return (0, i + 1)

encodeMacroBlock :: QuantificationTable
                 -> MutableMacroBlock s Int32
                 -> MutableMacroBlock s Int32
                 -> Int16
                 -> MutableMacroBlock s Int16
                 -> ST s (Int32, MutableMacroBlock s Int32)
encodeMacroBlock quantTableOfComponent workData finalData prev_dc block = do
 -- the inverse level shift is performed internally by the fastDCT routine
 blk <- fastDctLibJpeg workData block
        >>= zigZagReorderForward finalData
        >>= quantize quantTableOfComponent
 dc <- blk `M.unsafeRead` 0
 (blk `M.unsafeWrite` 0) $ dc - fromIntegral prev_dc
 return (dc, blk)

divUpward :: (Integral a) => a -> a -> a
divUpward n dividor = val + (if rest /= 0 then 1 else 0)
    where (val, rest) = n `divMod` dividor

prepareHuffmanTable :: DctComponent -> Word8 -> HuffmanTable
                    -> (JpgHuffmanTableSpec, HuffmanTreeInfo)
prepareHuffmanTable classVal dest tableDef = 
   (JpgHuffmanTableSpec { huffmanTableClass = classVal
                        , huffmanTableDest  = dest
                        , huffSizes = sizes
                        , huffCodes = V.fromListN 16
                            [VU.fromListN (fromIntegral $ sizes ! i) lst
                                                | (i, lst) <- zip [0..] tableDef ]
                        }, VS.singleton 0)
      where sizes = VU.fromListN 16 $ map (fromIntegral . length) tableDef   

-- | Encode an image in jpeg at a reasonnable quality level.
-- If you want better quality or reduced file size, you should
-- use `encodeJpegAtQuality`
encodeJpeg :: Image PixelYCbCr8 -> L.ByteString
encodeJpeg = encodeJpegAtQuality 50

-- | Function to call to encode an image to jpeg.
-- The quality factor should be between 0 and 100 (100 being
-- the best quality).
encodeJpegAtQuality :: Word8                -- ^ Quality factor
                    -> Image PixelYCbCr8    -- ^ Image to encode
                    -> L.ByteString         -- ^ Encoded JPEG
encodeJpegAtQuality quality img@(Image { imageWidth = w, imageHeight = h }) = encode finalImage
  where finalImage = JpgImage [ JpgQuantTable quantTables
                              , JpgScans JpgBaselineDCTHuffman hdr
                              , JpgHuffmanTable huffTables
                              , JpgScanBlob scanHeader encodedImage
                              ]

        huffTables = [ prepareHuffmanTable DcComponent 0 defaultDcLumaHuffmanTable
                     , prepareHuffmanTable AcComponent 0 defaultAcLumaHuffmanTable
                     , prepareHuffmanTable DcComponent 1 defaultDcChromaHuffmanTable
                     , prepareHuffmanTable AcComponent 1 defaultAcChromaHuffmanTable
                     ]

        outputComponentCount = 3

        scanHeader = scanHeader'{ scanLength = fromIntegral $ calculateSize scanHeader' }
        scanHeader' = JpgScanHeader
            { scanLength = 0
            , scanComponentCount = outputComponentCount
            , scans = [ JpgScanSpecification { componentSelector = 1
                                             , dcEntropyCodingTable = 0
                                             , acEntropyCodingTable = 0
                                             }
                      , JpgScanSpecification { componentSelector = 2
                                             , dcEntropyCodingTable = 1
                                             , acEntropyCodingTable = 1
                                             }
                      , JpgScanSpecification { componentSelector = 3
                                             , dcEntropyCodingTable = 1
                                             , acEntropyCodingTable = 1
                                             }
                      ]

            , spectralSelection = (0, 63)
            , successiveApproxHigh = 0
            , successiveApproxLow  = 0
            }

        hdr = hdr' { jpgFrameHeaderLength   = fromIntegral $ calculateSize hdr' }
        hdr' = JpgFrameHeader{ jpgFrameHeaderLength   = 0
                              , jpgSamplePrecision     = 8
                              , jpgHeight              = fromIntegral h
                              , jpgWidth               = fromIntegral w
                              , jpgImageComponentCount = outputComponentCount
                              , jpgComponents          = [
                                    JpgComponent { componentIdentifier      = 1
                                                 , horizontalSamplingFactor = 2
                                                 , verticalSamplingFactor   = 2
                                                 , quantizationTableDest    = 0
                                                 }
                                  , JpgComponent { componentIdentifier      = 2
                                                 , horizontalSamplingFactor = 1
                                                 , verticalSamplingFactor   = 1
                                                 , quantizationTableDest    = 1
                                                 }
                                  , JpgComponent { componentIdentifier      = 3
                                                 , horizontalSamplingFactor = 1
                                                 , verticalSamplingFactor   = 1
                                                 , quantizationTableDest    = 1
                                                 }
                                  ]
                              }

        lumaQuant = scaleQuantisationMatrix (fromIntegral quality)
                        defaultLumaQuantizationTable 
        chromaQuant = scaleQuantisationMatrix (fromIntegral quality)
                            defaultChromaQuantizationTable

        zigzagedLumaQuant = zigZagReorderForwardv lumaQuant
        zigzagedChromaQuant = zigZagReorderForwardv chromaQuant 
        quantTables = [ JpgQuantTableSpec { quantPrecision = 0, quantDestination = 0
                                          , quantTable = zigzagedLumaQuant }
                      , JpgQuantTableSpec { quantPrecision = 0, quantDestination = 1
                                          , quantTable = zigzagedChromaQuant }
                      ]

        encodedImage = runST toExtract
        toExtract = runBoolWriter $ do
            let horizontalMetaBlockCount = w `divUpward` (8 * maxSampling)
                verticalMetaBlockCount = h `divUpward` (8 * maxSampling)
                maxSampling = 2
                lumaSamplingSize = ( maxSampling, maxSampling, zigzagedLumaQuant
                                   , makeInverseTable defaultDcLumaHuffmanTree
                                   , makeInverseTable defaultAcLumaHuffmanTree)
                chromaSamplingSize = ( maxSampling - 1, maxSampling - 1, zigzagedChromaQuant
                                     , makeInverseTable defaultDcChromaHuffmanTree
                                     , makeInverseTable defaultAcChromaHuffmanTree)
                componentDef = [lumaSamplingSize, chromaSamplingSize, chromaSamplingSize]
  
                imageComponentCount = length componentDef

            dc_table <- lift $ M.replicate 3 0
            block <- lift createEmptyMutableMacroBlock
            workData <- lift createEmptyMutableMacroBlock
            zigzaged <- lift createEmptyMutableMacroBlock

            -- It's ugly, I know, be avoid allocation
            let blockLine my | my >= verticalMetaBlockCount = return ()
                blockLine my = blockColumn 0
                  where blockColumn mx | mx >= horizontalMetaBlockCount = blockLine (my + 1)
                        blockColumn mx = component $ zip [0..] componentDef
                          where component [] = blockColumn (mx + 1)
                                component ((comp, (sizeX, sizeY, table, dc, ac)) : comp_rest) = line 0
                                  where xSamplingFactor = maxSampling - sizeX + 1
                                        ySamplingFactor = maxSampling - sizeY + 1
                                        extractor = extractBlock img block xSamplingFactor ySamplingFactor imageComponentCount 
                                        line subY | subY >= sizeY = component comp_rest
                                        line subY = column 0
                                           where blockY = my * sizeY + subY
                                                 
                                                 column subX | subX >= sizeX = line (subY + 1)
                                                 column subX = do
                                                    let blockX = mx * sizeX + subX
                                                    prev_dc <- lift $ dc_table `M.unsafeRead` comp
                                                    (dc_coeff, neo_block) <- lift (extractor comp blockX blockY >>= 
                                                                            encodeMacroBlock table workData zigzaged prev_dc)
                                                    lift . (dc_table `M.unsafeWrite` comp) $ fromIntegral dc_coeff
                                                    serializeMacroBlock dc ac neo_block
                                                    column $ subX + 1
            blockLine 0
