local Translator = torch.class('Translator')
local nnq = require ('nnquery')

local options = {
  {'-model', '', [[Path to model .t7 file]], {valid=onmt.utils.ExtendedCmdLine.nonEmpty}},
  {'-beam_size', 5, [[Beam size]]},
  {'-batch_size', 30, [[Batch size]]},
  {'-max_sent_length', 250, [[Maximum output sentence length.]]},
  {'-replace_unk', false, [[Replace the generated UNK tokens with the source token that
                          had the highest attention weight. If phrase_table is provided,
                          it will lookup the identified source token and give the corresponding
                          target token. If it is not provided (or the identified source token
                          does not exist in the table) then it will copy the source token]]},
  {'-phrase_table', '', [[Path to source-target dictionary to replace UNK
                        tokens. See README.md for the format this file should be in]]},
  {'-n_best', 1, [[If > 1, it will also output an n_best list of decoded sentences]]},
  {'-max_num_unks', math.huge, [[All sequences with more unks than this will be ignored
                               during beam search]]},
  {'-pre_filter_factor', 1, [[Optional, set this only if filter is being used. Before
                            applying filters, hypotheses with top `beamSize * preFilterFactor`
                            scores will be considered. If the returned hypotheses voilate filters,
                            then set this to a larger value to consider more.]]},
  {'-gate', false, [[Using Gating Network.]]},
  {'-concat', false, [[Using Concat Network.]]},
  {'-gating_type', 'contextBiEncoder', [[Gating Network]],
                    {enum={'contextBiEncoder', 'leave_one_out', 'conv', 'cbow'}}}
}

function Translator.declareOpts(cmd)
  cmd:setCmdLineOptions(options, 'Translator')
end


function Translator:__init(args)
  self.opt = args
  onmt.utils.Cuda.init(self.opt)

  _G.logger:info('Loading \'' .. self.opt.model .. '\'...')
  self.checkpoint = torch.load(self.opt.model)

  self.models = {}
  

  self.models.encoder = onmt.Factory.loadEncoder(self.checkpoint.models.encoder)
  self.models.decoder = onmt.Factory.loadDecoder(self.checkpoint.models.decoder)

  self.models.encoder:evaluate()
  self.models.decoder:evaluate()

  onmt.utils.Cuda.convert(self.models.encoder)
  onmt.utils.Cuda.convert(self.models.decoder)

  if self.opt.gate or self.opt.concat == true then
    self.models.gatingNetwork = onmt.Factory.loadGatingNetwork(self.checkpoint.models.gatingNetwork)
    self.models.gatingNetwork:evaluate()
    onmt.utils.Cuda.convert(self.models.gatingNetwork)
  end


  self.dicts = self.checkpoint.dicts

  if self.opt.phrase_table:len() > 0 then
    self.phraseTable = onmt.translate.PhraseTable.new(self.opt.phrase_table)
  end
end

function Translator:buildInput(tokens)
  local words, features = onmt.utils.Features.extract(tokens)

  local data = {}
  data.words = words

  if #features > 0 then
    data.features = features
  end

  return data
end

function Translator:buildOutput(data)
  return table.concat(onmt.utils.Features.annotate(data.words, data.features), ' ')
end

function Translator:buildData(src, gold)
  local srcData = {}
  srcData.words = {}
  srcData.features = {}

  local goldData
  if gold then
    goldData = {}
    goldData.words = {}
    goldData.features = {}
  end

  local ignored = {}
  local indexMap = {}
  local index = 1

  for b = 1, #src do
    if #src[b].words == 0 then
      table.insert(ignored, b)
    else
      indexMap[index] = b
      index = index + 1

      table.insert(srcData.words,
                   self.dicts.src.words:convertToIdx(src[b].words, onmt.Constants.UNK_WORD))

      if #self.dicts.src.features > 0 then
        table.insert(srcData.features,
                     onmt.utils.Features.generateSource(self.dicts.src.features, src[b].features))
      end

      if gold then
        table.insert(goldData.words,
                     self.dicts.tgt.words:convertToIdx(gold[b].words,
                                                       onmt.Constants.UNK_WORD,
                                                       onmt.Constants.BOS_WORD,
                                                       onmt.Constants.EOS_WORD))

        if #self.dicts.tgt.features > 0 then
          table.insert(goldData.features,
                       onmt.utils.Features.generateTarget(self.dicts.tgt.features, gold[b].features))
        end
      end
    end
  end

  return onmt.data.Dataset.new(srcData, goldData), ignored, indexMap
end

function Translator:buildTargetWords(pred, src, attn)
  local tokens = self.dicts.tgt.words:convertToLabels(pred, onmt.Constants.EOS)

  if self.opt.replace_unk then
    for i = 1, #tokens do
      if tokens[i] == onmt.Constants.UNK_WORD then
        local _, maxIndex = attn[i]:max(1)
        local source = src[maxIndex[1]]

        if self.phraseTable and self.phraseTable:contains(source) then
          tokens[i] = self.phraseTable:lookup(source)
        else
          tokens[i] = source
        end
      end
    end
  end

  return tokens
end

function Translator:buildTargetFeatures(predFeats)
  local numFeatures = #predFeats[1]
  if numFeatures == 0 then
    return {}
  end

  local feats = {}
  for _ = 1, numFeatures do
    table.insert(feats, {})
  end

  for i = 2, #predFeats do
    for j = 1, numFeatures do
      table.insert(feats[j], self.dicts.tgt.features[j]:lookup(predFeats[i][j]))
    end
  end

  return feats
end

function Translator:translateBatch(batch)
  local rnnSize = nil
  local gatingEncStates = nil
  local gatingContext = nil
  if self.opt.gate or self.opt.concat then
    self.models.gatingNetwork:maskPadding()
    rnnSize = self.models.gatingNetwork.args.rnnSize
    -- gatingContext: batch x rho x dim tensor
    if self.opt.gating_type == 'contextBiEncoder' then
      gatingEncStates, gatingContext = self.models.gatingNetwork:forward(batch)
      --print(gatingContext:size())
    elseif self.opt.gating_type == 'leave_one_out' then
      gatingContext = {}
      for t = 1, batch.sourceLength do
        local gateInputBatch = onmt.utils.Tensor.deepClone(batch)
        gateInputBatch.sourceInput[t]:fill(onmt.Constants.DOL)
        local finalStates, context = self.models.gatingNetwork:forward(gateInputBatch)
        table.insert(gatingContext, finalStates[#finalStates]) -- gatingContext then becomes rho x batch x dim -> need to transpose later
      end
      gatingContext = torch.cat(gatingContext, 1):resize(batch.sourceLength, batch.size, self.models.gatingNetwork.args.rnnSize)
      gatingContext = gatingContext:transpose(1,2) -- swapping dim1 with dim2 -> batch x rho x dim
    elseif self.opt.gating_type == 'conv' then
        gatingContext = self.models.gatingNetwork:forward(batch)
    elseif self.opt.gating_type == 'cbow' then
        gatingVector = self.models.gatingNetwork:forward(batch)
        local replica = nn.Replicate(batch.sourceLength, 2)
        if #onmt.utils.Cuda.gpuIds > 0 then
          replica:cuda()
        end
        gatingContext = replica:forward(gatingVector)
    end
    batch:setGateTensor(gatingContext)
    --batch:setGateTensor(torch.Tensor(batch.size, batch.sourceLength, self.models.gatingNetwork.args.rnnSize):fill(1):cuda())
    -- print(gatingContext)
  end
  self.models.encoder:maskPadding()
  self.models.decoder:maskPadding()

  local encStates, context = self.models.encoder:forward(batch)

  -- Compute gold score.
  local goldScore
  if batch.targetInput ~= nil then
    if batch.size > 1 then
      self.models.decoder:maskPadding(batch.sourceSize, batch.sourceLength)
    end
    goldScore = self.models.decoder:computeScore(batch, encStates, context)
  end

  -- Specify how to go one step forward.
  local advancer = onmt.translate.DecoderAdvancer.new(self.models.decoder,
                                                      batch,
                                                      context,
                                                      self.opt.max_sent_length,
                                                      self.opt.max_num_unks,
                                                      encStates,
                                                      self.dicts)

  -- Save memory by only keeping track of necessary elements in the states.
  -- Attentions are at index 4 in the states defined in onmt.translate.DecoderAdvancer.
  local attnIndex = 4

  -- Features are at index 5 in the states defined in onmt.translate.DecoderAdvancer.
  local featsIndex = 5

  advancer:setKeptStateIndexes({attnIndex, featsIndex})

  -- Conduct beam search.
  local beamSearcher = onmt.translate.BeamSearcher.new(advancer)
  local results = beamSearcher:search(self.opt.beam_size, self.opt.n_best, self.opt.pre_filter_factor)

  local allHyp = {}
  local allFeats = {}
  local allAttn = {}
  local allScores = {}

  for b = 1, batch.size do
    local hypBatch = {}
    local featsBatch = {}
    local attnBatch = {}
    local scoresBatch = {}

    for n = 1, self.opt.n_best do
      local result = results[b][n]
      local tokens = result.tokens
      local score = result.score
      local states = result.states
      local attn = states[attnIndex] or {}
      local feats = states[featsIndex] or {}
      table.remove(tokens)

      -- Remove unnecessary values from the attention vectors.
      local size = batch.sourceSize[b]
      for j = 1, #attn do
        attn[j] = attn[j]:narrow(1, batch.sourceLength - size + 1, size)
      end

      table.insert(hypBatch, tokens)
      if #feats > 0 then
        table.insert(featsBatch, feats)
      end
      table.insert(attnBatch, attn)
      table.insert(scoresBatch, score)
    end

    table.insert(allHyp, hypBatch)
    table.insert(allFeats, featsBatch)
    table.insert(allAttn, attnBatch)
    table.insert(allScores, scoresBatch)
  end

  return allHyp, allFeats, allScores, allAttn, goldScore
end

--[[ Translate a batch of source sequences.

Parameters:

  * `src` - a batch of tables containing:
    - `words`: the table of source words
    - `features`: the table of feaures sequences (`src.features[i][j]` is the value of the ith feature of the jth token)
  * `gold` - gold data to compute confidence score (same format as `src`)

Returns:

  * `results` - a batch of tables containing:
    - `goldScore`: if `gold` was given, this is the confidence score
    - `preds`: an array of `opt.n_best` tables containing:
      - `words`: the table of target words
      - `features`: the table of target features sequences
      - `attention`: the attention vectors of each target word over the source words
      - `score`: the confidence score of the prediction
]]
function Translator:translate(src, gold)
  local data, ignored, indexMap = self:buildData(src, gold)

  local results = {}

  if data:batchCount() > 0 then
    local batch = data:getBatch()

    local pred, predFeats, predScore, attn, goldScore = self:translateBatch(batch)

    for b = 1, batch.size do
      results[b] = {}

      results[b].preds = {}
      for n = 1, self.opt.n_best do
        results[b].preds[n] = {}
        results[b].preds[n].words = self:buildTargetWords(pred[b][n], src[indexMap[b]].words, attn[b][n])
        results[b].preds[n].features = self:buildTargetFeatures(predFeats[b][n])
        results[b].preds[n].attention = attn[b][n]
        results[b].preds[n].score = predScore[b][n]
      end

      if goldScore ~= nil then
        results[b].goldScore = goldScore[b]
      end
    end
  end

  for i = 1, #ignored do
    table.insert(results, ignored[i], {})
  end

  return results
end

function Translator:extractWordEmbeddingBatch(batch)
  local rnnSize = nil
  local gatingEncStates = nil
  local gatingContext = nil
  if self.opt.gate or self.opt.concat then
    self.models.gatingNetwork:maskPadding()
    rnnSize = self.models.gatingNetwork.args.rnnSize
    -- gatingContext: batch x rho x dim tensor
    if self.opt.gating_type == 'contextBiEncoder' then
      gatingEncStates, gatingContext = self.models.gatingNetwork:forward(batch)
    elseif self.opt.gating_type == 'leave_one_out' then
      gatingContext = {}
      for t = 1, batch.sourceLength do
        local gateInputBatch = onmt.utils.Tensor.deepClone(batch)
        gateInputBatch.sourceInput[t]:fill(onmt.Constants.DOL)
        local finalStates, context = self.models.gatingNetwork:forward(gateInputBatch)
        table.insert(gatingContext, finalStates[#finalStates]) -- gatingContext then becomes rho x batch x dim -> need to transpose later
      end
      gatingContext = torch.cat(gatingContext, 1):resize(batch.sourceLength, batch.size, self.models.gatingNetwork.args.rnnSize)
      gatingContext = gatingContext:transpose(1,2) -- swapping dim1 with dim2 -> batch x rho x dim
    elseif self.opt.gating_type == 'conv' then
        gatingContext = self.models.gatingNetwork:forward(batch)
    elseif self.opt.gating_type == 'cbow' then
        gatingVector = self.models.gatingNetwork:forward(batch)
        local replica = nn.Replicate(batch.sourceLength, 2)
        if #onmt.utils.Cuda.gpuIds > 0 then
          replica:cuda()
        end
        gatingContext = replica:forward(gatingVector)
    end
    batch:setGateTensor(gatingContext)
  end
  self.models.encoder:maskPadding()
  self.models.decoder:maskPadding()
  local wordEmbedding = {}
  for t = 1, batch.sourceLength do
    if self.models.encoder.name == 'Encoder' then
      table.insert(wordEmbedding, nnq(self.models.encoder.modules[1]):descendants()[13]:val().data.module:forward(batch:getSourceInput(t)):clone()) -- append 1 x 500 to wordEmbedding
    else
      table.insert(wordEmbedding, nnq(self.models.encoder.modules[1].modules[1]):descendants()[13]:val().data.module:forward(batch:getSourceInput(t)):clone())
    end
  end
  wordEmbedding = torch.cat(wordEmbedding, 1) -- table -> tensor
  return wordEmbedding:double()
end

function Translator:extractWordEmbedding(src)
  local data, ignored, indexMap = self:buildData(src, nil)
  local results = {}
  local batch = data:getBatch()
  assert(batch.size == 1)
  local embedding = self:extractWordEmbeddingBatch(batch)
  return embedding
end

return Translator
