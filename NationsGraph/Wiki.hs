{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module NationsGraph.Wiki (
    redirectParser,
    wikiParser,
    getInfobox,
    wikiList,
    findTemplate,
) where

import NationsGraph.Types

import Data.List
import Data.List.NonEmpty hiding (filter,map)
import qualified Data.List.NonEmpty
import qualified Data.Map as M
import Data.Monoid
import Data.Maybe
import Data.Char

import Control.Monad
import Control.Applicative as A

import Control.Lens

import qualified Data.Text as T

import qualified Data.Attoparsec.Text as AP

import Control.Error.Util

import Safe

emptyNode :: WikiNode -> Bool
emptyNode (WikiText t) = T.null t
emptyNode _ = False

wikiRemoveComments :: Wiki -> Maybe Wiki
wikiRemoveComments =
    fmap Wiki . nonEmpty .
    Data.List.NonEmpty.filter (\case 
        WikiComment _ -> False
        _ -> True
    ) .
    wikiList

wikiFlatten :: Wiki -> Wiki
wikiFlatten (Wiki (x:|xs)) = case (x,foldl' wikiFlattenFold [] xs) of
    (WikiText a, WikiText b:xs) -> Wiki $ WikiText (a<>b) :| xs
    (_,ys) -> Wiki $ x:|ys  
wikiFlattenFold :: [WikiNode] -> WikiNode -> [WikiNode]
wikiFlattenFold (WikiText b:acc) (WikiText a) =
    WikiText (a <> b) : acc
wikiFlattenFold acc a = a:acc

nonDouble :: Char -> AP.Parser Char
nonDouble c = do
    AP.char c
    peek <- AP.peekChar
    case peek of
        Just c' -> if c == c' then A.empty else return c
        Nothing -> return c

xmlComment :: AP.Parser WikiNode
xmlComment = do
    "<!--"
    content <- many $ nonDash <|> singleDash
    "-->"
    return $ WikiComment $ T.pack $ concat content
    where
    nonDash = (:[]) <$> AP.notChar '-'
    singleDash = do
        AP.char '-'
        c <- AP.notChar '-'
        return ['-',c]

xmlName :: AP.Parser T.Text
xmlName = do
    c1 <- AP.letter <|> AP.char '_' <|> AP.char ':'
    rest <- AP.takeWhile $ \ c ->
        isLetter c || isDigit c || (c `elem` (".-_:" :: String))
    return $ T.cons c1 rest

xmlAttribute :: AP.Parser (T.Text,T.Text)
xmlAttribute = do
    name <- xmlName
    "=\""
    value <- AP.takeWhile(\ c -> c /= '>' && not (isSpace c))
    return (name,value)

xmlTag :: AP.Parser (T.Text,M.Map T.Text T.Text)
xmlTag = do
    "</" <|> "<"
    name <- xmlName
    attributes <- A.many $ AP.takeWhile isSpace *> xmlAttribute
    AP.takeWhile isSpace
    ">"<|> "/>"
    return (name, M.fromList attributes)

xmlSpecificTag :: T.Text -> AP.Parser (T.Text,M.Map T.Text T.Text)
xmlSpecificTag name = do
    "<" <|> "</"
    AP.string name
    attributes <- A.many $ AP.takeWhile isSpace *> xmlAttribute
    AP.takeWhile isSpace
    ">"<|> "/>"
    return (name, M.fromList attributes)

wikiParser = do
    begin <-xmlComment <|>
            wikiHTMLTagParser <|>
            wikiLinkParser <|>
            wikiTemplateParser <|>
            WikiText <$> ("<"<|>">") <|>
            (WikiText <$> T.singleton <$> foldr ((<|>) . nonDouble) A.empty ("{}[]"::String)) <|>
            (WikiText <$> AP.takeWhile (AP.notInClass "{}[]<>|"))
    if emptyNode begin
    then return $ Wiki $ begin:|[]
    else (AP.endOfInput >> (return $ Wiki $ begin:|[])) <|> do
        Wiki (n:|ns) <- wikiParser
        return $ if emptyNode n
            then Wiki $ begin:|[]
            else Wiki $ begin:|(n:ns)

wikiHTMLTagParser :: AP.Parser WikiNode
wikiHTMLTagParser = do
    (name, attributes) <- xmlTag
    return $ WikiHTMLTag name attributes
    
wikiLinkParser :: AP.Parser WikiNode
wikiLinkParser = do
    "[["
    first <- AP.takeWhile (\ c -> c /= '|' && c /= ']')
    peek <- AP.peekChar
    rest <- many $ "|" *> wikiParser
    "]]"
    return $ WikiLink first rest

wikiTemplateNamedParameter :: AP.Parser (T.Text,Wiki)
wikiTemplateNamedParameter = do
    "|"
    key <- AP.takeWhile (\ c -> c /='|' && c /= '=' && c /= '}')
    "="
    value <- wikiParser
    return (T.strip key,value)

wikiTemplateUnNamedParameter :: AP.Parser Wiki
wikiTemplateUnNamedParameter = do
    "|"
    wikiParser

wikiTemplateParser :: AP.Parser WikiNode
wikiTemplateParser = do
    "{{"
    title <- AP.takeWhile (\ c -> c /= '|' && c /= '}')
    parameters <- A.many $ fmap Right wikiTemplateNamedParameter <|> fmap Left wikiTemplateUnNamedParameter
    "}}"
    return $ WikiTemplate (T.strip title) [x | Left x <- parameters] $ M.fromList [x | Right x <- parameters] 

redirectParser :: AP.Parser T.Text
redirectParser = do
    "#REDIRECT"
    A.many AP.space
    WikiLink link _ <- wikiLinkParser
    return link

yearParser :: AP.Parser Int
yearParser = do
    digits <- many $ AP.satisfy isDigit
    absYear <- maybe (fail "Year did not read as Int") return $ readMay digits 
    (AP.endOfInput >> return absYear) <|> do
        many (AP.satisfy isSeparator)
        "BC"
        AP.endOfInput
        return $ -absYear

readYearMay :: T.Text -> Maybe Int
readYearMay = either (const Nothing) Just .
    AP.parseOnly yearParser . T.strip

findTemplate :: T.Text -> Wiki -> Maybe WikiNode
findTemplate target = getFirst . foldMap (First . 
    \case 
        t@(WikiTemplate title _ _) -> if T.toLower title == target then Just t else Nothing
        _ -> Nothing
    ) . wikiList

propLookup :: T.Text -> M.Map T.Text Wiki -> Maybe T.Text
propLookup prop props = case wikiList <$> M.lookup prop props of
    Just (WikiText x:|_)   -> Just $ x
    Just (WikiLink x _:|_) -> Just $ x
    _ -> Nothing

getInfobox :: Wiki -> Either HistoryError Infobox
getInfobox wiki = case (findTemplate "infobox former country" wiki,
                        findTemplate "infobox former subdivision" wiki) of
        (Just _, Just _) -> Left DoubleInfobox
        (Just (WikiTemplate title _ props), Nothing) ->
            note InfoboxInterpretationError $
                NationInfobox <$>
                name props <*>
                pure (startYear props) <*>
                pure (endYear props) <*>
                conn props 'p' <*>
                conn props 's'
        (Nothing, Just (WikiTemplate title _ props)) ->
            note InfoboxInterpretationError $
                SubdivisionInfobox <$>
                name props <*>
                pure (startYear props) <*>
                pure (endYear props) <*>
                conn props 'p' <*>
                conn props 's'<*>
                pure (parents props)
        (Nothing,Nothing) -> Left MissingInfobox
        where
            conn :: M.Map T.Text Wiki -> Char -> Maybe [String]
            conn props ty = let
                raw = mapMaybe (\ i -> wikiRemoveComments =<< M.lookup (T.pack $ ty:show i) props) [1..15]
                in filter (not . null) <$> map (T.unpack . T.strip) <$> traverse propTextContent raw

            propTextContent :: Wiki -> Maybe T.Text
            propTextContent (Wiki (WikiText text:|[])) = Just text
            propTextContent (Wiki (WikiText text :| WikiTemplate "!" _ _ : _)) = Just text
            propTextContent _ = Nothing

            parents :: M.Map T.Text Wiki -> [String]
            parents props = [T.unpack nationName |
                WikiLink nationName _<- props^.ix "nation".to (toList.wikiList)]

            name = fmap (T.unpack . T.strip) . propLookup "conventional_long_name"

            startYear :: M.Map T.Text Wiki -> Maybe Int
            startYear = readYearMay <=< propLookup "year_start"

            endYear :: M.Map T.Text Wiki -> Maybe Int
            endYear = readYearMay <=< propLookup "year_end"